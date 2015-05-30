{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
module CoreToIR where

import Data.List
import Debug.Trace
import Control.Applicative
import Control.Monad.State
import Data.Monoid
import Data.Foldable (Foldable)
import qualified Data.Foldable as F
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map (Map)
import qualified Data.Map as Map

import Pretty
import qualified Type as AST
import Type
import CoreToGLSL
import qualified IR as IR

type CG = State IR.Pipeline

emptyPipeline b = IR.Pipeline b mempty mempty mempty mempty mempty mempty
updateList i x xs = take i xs ++ x : drop (i+1) xs

imageToSemantic :: IR.Image -> (IR.ImageSemantic, IR.Value)
imageToSemantic a = case a of
  IR.DepthImage _ v   -> (IR.Depth, IR.VFloat v)
  IR.StencilImage _ v -> (IR.Stencil, IR.VInt v)
  IR.ColorImage _ v   -> (IR.Color, v)

newRenderTarget :: [IR.Image] -> CG IR.RenderTargetName
newRenderTarget a = do
  tv <- gets IR.targets
  let t = IR.RenderTarget [(s,Just (IR.Framebuffer s)) | i <- a, let s = fst (imageToSemantic i)]
  modify (\s -> s {IR.targets = tv ++ [t]})
  return $ length tv

compilePipeline :: IR.Backend -> Exp -> IR.Pipeline
compilePipeline b e = flip execState (emptyPipeline b) $ do
    c <- getCommands e
    modify (\s -> s {IR.commands = c})

mergeSlot a b = a
  { IR.slotUniforms = IR.slotUniforms a <> IR.slotUniforms b
  , IR.slotStreams  = IR.slotStreams a <> IR.slotStreams b
  , IR.slotPrograms = IR.slotPrograms a <> IR.slotPrograms b
  }

getSlot :: Exp -> CG (IR.SlotName,[(String,IR.InputType)])
getSlot (A3 "Fetch" (ELit (LString slotName)) prim attrs) = do
  let input = compAttribute attrs
      slot = IR.Slot
        { IR.slotName       = slotName
        , IR.slotUniforms   = mempty
        , IR.slotStreams    = Map.fromList input
        , IR.slotPrimitive  = compFetchPrimitive prim
        , IR.slotPrograms   = []
        }
  sv <- gets IR.slots
  case findIndex ((slotName ==) . IR.slotName) sv of
    Nothing -> do
      modify (\s -> s {IR.slots = sv ++ [slot]})
      return (length sv,input)
    Just i -> do
      modify (\s -> s {IR.slots = updateList i (mergeSlot (sv !! i) slot) sv})
      return (i,input)
getSlot x = error $ "getSlot: " ++ ppShow x

addProgramToSlot :: IR.ProgramName -> IR.SlotName -> CG ()
addProgramToSlot prgName slotName = do
  sv <- gets IR.slots
  pv <- gets IR.programs
  let slot = sv !! slotName
      prg = pv !! prgName
      slot' = slot
        { IR.slotUniforms = IR.slotUniforms slot <> IR.programUniforms prg
        , IR.slotPrograms = IR.slotPrograms slot <> [prgName]
        }
  modify (\s -> s {IR.slots = updateList slotName slot' sv})

getProgram :: [(String,IR.InputType)] -> IR.SlotName -> Exp -> Exp -> CG IR.ProgramName
getProgram input slot vert frag = do
  backend <- gets IR.backend
  let ((vertexInput,vertOut),vertSrc) = genVertexGLSL backend vert
      fragSrc = genFragmentGLSL backend vertOut frag
      prg = IR.Program
        { IR.programUniforms    = Map.fromList $ Set.toList $ getUniforms vert <> getUniforms frag
        , IR.programStreams     = Map.fromList $ zip vertexInput input
        , IR.programInTextures  = mempty -- TODO
        , IR.programOutput      = [("f0",IR.V4F)] -- TODO
        , IR.vertexShader       = vertSrc
        , IR.geometryShader     = mempty -- TODO
        , IR.fragmentShader     = fragSrc
        }
  pv <- gets IR.programs
  modify (\s -> s {IR.programs = pv ++ [prg]})
  let prgName = length pv
  addProgramToSlot prgName slot
  return prgName

getRenderTextures :: Exp -> [Exp]
getRenderTextures e = case e of
  A3 "Sampler" _ _ (A2 "Texture2D" _ _) -> [e]
  Exp e -> F.foldMap getRenderTextures e

getRenderTextureCommands :: Exp -> CG [IR.Command]
getRenderTextureCommands e = liftM concat $ forM (getRenderTextures e) $ \case
  A3 "Sampler" _ _ (A2 "Texture2D" _ (A1 "PrjImageColor" a)) -> getCommands a
  x -> error $ "getRenderTextureCommands: not supported render texture exp: " ++ ppShow x

getCommands :: Exp -> CG [IR.Command]
getCommands e = case e of
  A1 "ScreenOut" a -> getCommands a
  A5 "Accumulate" actx ffilter frag (A2 "Rasterize" rctx (A2 "Transform" vert input)) fbuf -> do
    vertCmds <- getRenderTextureCommands vert
    fragCmds <- getRenderTextureCommands frag
    (slot,input) <- getSlot input
    prog <- getProgram input slot vert frag
    fbufCommands <- getCommands fbuf
    return $ concat [vertCmds, fragCmds, fbufCommands, [IR.SetRasterContext (compRC rctx), IR.SetAccumulationContext (compAC actx), IR.SetProgram prog, IR.RenderSlot slot]]
  A1 "FrameBuffer" a -> do
    let i = compImg a
    rt <- newRenderTarget i
    pure [IR.SetRenderTarget rt, IR.ClearRenderTarget (map imageToSemantic i)]
  x -> error $ "getCommands " ++ ppShow x

getUniforms :: Exp -> Set (String,IR.InputType)
getUniforms e = case e of
  A1 "Uniform" (ELString s) -> Set.singleton (s, compInputType $ tyOf e)
  Exp e -> F.foldMap getUniforms e

compAC x = case x of
  A1 "AccumulationContext" (ETuple a) -> IR.AccumulationContext Nothing (map compFrag a)
  A1 "AccumulationContext" a -> IR.AccumulationContext Nothing [compFrag a]
  x -> error $ "compAC " ++ ppShow x

compBlending x = case x of
  A0 "NoBlending" -> IR.NoBlending
  A1 "BlendLogicOp" a -> IR.BlendLogicOp (compLO a)
  A3 "Blend" (ETuple [a,b]) (ETuple [ETuple [c,d],ETuple [e,f]]) (compValue -> IR.VV4F g) -> IR.Blend (compBE a,compBE b) ((compBF c,compBF d),(compBF e,compBF f)) g
  x -> error $ "compBlending " ++ ppShow x

compBF x = case x of
  A0 "Zero" -> IR.Zero
  A0 "One" -> IR.One
  A0 "SrcColor" -> IR.SrcColor
  A0 "OneMinusSrcColor" -> IR.OneMinusSrcColor
  A0 "DstColor" -> IR.DstColor
  A0 "OneMinusDstColor" -> IR.OneMinusDstColor
  A0 "SrcAlpha" -> IR.SrcAlpha
  A0 "OneMinusSrcAlpha" -> IR.OneMinusSrcAlpha
  A0 "DstAlpha" -> IR.DstAlpha
  A0 "OneMinusDstAlpha" -> IR.OneMinusDstAlpha
  A0 "ConstantColor" -> IR.ConstantColor
  A0 "OneMinusConstantColor" -> IR.OneMinusConstantColor
  A0 "ConstantAlpha" -> IR.ConstantAlpha
  A0 "OneMinusConstantAlpha" -> IR.OneMinusConstantAlpha
  A0 "SrcAlphaSaturate" -> IR.SrcAlphaSaturate
  x -> error $ "compBF " ++ ppShow x

compBE x = case x of
  A0 "FuncAdd" -> IR.FuncAdd
  A0 "FuncSubtract" -> IR.FuncSubtract
  A0 "FuncReverseSubtract" -> IR.FuncReverseSubtract
  A0 "Min" -> IR.Min
  A0 "Max" -> IR.Max
  x -> error $ "compBE " ++ ppShow x

compLO x = case x of
  A0 "Clear" -> IR.Clear
  A0 "And" -> IR.And
  A0 "AndReverse" -> IR.AndReverse
  A0 "Copy" -> IR.Copy
  A0 "AndInverted" -> IR.AndInverted
  A0 "Noop" -> IR.Noop
  A0 "Xor" -> IR.Xor
  A0 "Or" -> IR.Or
  A0 "Nor" -> IR.Nor
  A0 "Equiv" -> IR.Equiv
  A0 "Invert" -> IR.Invert
  A0 "OrReverse" -> IR.OrReverse
  A0 "CopyInverted" -> IR.CopyInverted
  A0 "OrInverted" -> IR.OrInverted
  A0 "Nand" -> IR.Nand
  A0 "Set" -> IR.Set
  x -> error $ "compLO " ++ ppShow x

compComparisonFunction x = case x of
  A0 "Never" -> IR.Never
  A0 "Less" -> IR.Less
  A0 "Equal" -> IR.Equal
  A0 "Lequal" -> IR.Lequal
  A0 "Greater" -> IR.Greater
  A0 "Notequal" -> IR.Notequal
  A0 "Gequal" -> IR.Gequal
  A0 "Always" -> IR.Always
  x -> error $ "compComparisonFunction " ++ ppShow x

compBool x = case x of
  A0 "True" -> True
  A0 "False" -> False
  x -> error $ "compBool " ++ ppShow x

compFrag x = case x of
  A2 "DepthOp" (compComparisonFunction -> a) (compBool -> b) -> IR.DepthOp a b
  A2 "ColorOp" (compBlending -> b) (compValue -> v) -> IR.ColorOp b v
  x -> error $ "compFrag " ++ ppShow x

compInputType x = case x of
  TFloat          -> IR.Float
  TVec 2 TFloat   -> IR.V2F
  TVec 3 TFloat   -> IR.V3F
  TVec 4 TFloat   -> IR.V4F
  TBool           -> IR.Bool
  TVec 2 TBool    -> IR.V2B
  TVec 3 TBool    -> IR.V3B
  TVec 4 TBool    -> IR.V4B
  TInt            -> IR.Int
  TVec 2 TInt     -> IR.V2I
  TVec 3 TInt     -> IR.V3I
  TVec 4 TInt     -> IR.V4I
  TWord           -> IR.Word
  TVec 2 TWord    -> IR.V2U
  TVec 3 TWord    -> IR.V3U
  TVec 4 TWord    -> IR.V4U
  TMat 2 2 TFloat -> IR.M22F
  TMat 2 3 TFloat -> IR.M23F
  TMat 2 4 TFloat -> IR.M24F
  TMat 3 2 TFloat -> IR.M32F
  TMat 3 3 TFloat -> IR.M33F
  TMat 3 4 TFloat -> IR.M34F
  TMat 4 2 TFloat -> IR.M42F
  TMat 4 3 TFloat -> IR.M43F
  TMat 4 4 TFloat -> IR.M44F
  x -> error $ "compInputType " ++ ppShow x

compAttribute x = case x of
  ETuple a -> concatMap compAttribute a
  A1 "Attribute" (ELString s) -> [(s, compInputType $ tyOf x)]
  x -> error $ "compAttribute " ++ ppShow x

compFetchPrimitive x = case x of
  A0 "Points" -> IR.Points
  A0 "Lines" -> IR.Lines
  A0 "Triangles" -> IR.Triangles
  A0 "LinesAdjacency" -> IR.LinesAdjacency
  A0 "TrianglesAdjacency" -> IR.TrianglesAdjacency
  x -> error $ "compFetchPrimitive " ++ ppShow x

compImg x = case x of
  ETuple a -> concatMap compImg a
  A2 "DepthImage" (ENat i) (ELit (LFloat a)) -> [IR.DepthImage i (realToFrac a)]
  A2 "ColorImage" (ENat i) a -> [IR.ColorImage i (compValue a)]
  x -> error $ "compImg " ++ ppShow x

compValue x = case x of
  ELit (LFloat a) -> IR.VFloat $ realToFrac a
  ELit (LInt a) -> IR.VInt $ fromIntegral a
  A4 "V4" (ELit (LFloat a)) (ELit (LFloat b)) (ELit (LFloat c)) (ELit (LFloat d)) -> IR.VV4F $ IR.V4 (realToFrac a) (realToFrac b) (realToFrac c) (realToFrac d)
  A4 "V4" (compBool -> a) (compBool -> b) (compBool -> c) (compBool -> d) -> IR.VV4B $ IR.V4 a b c d
  x -> error $ "compValue " ++ ppShow x

compRC x = case x of
  A3 "PointCtx" a (ELit (LFloat b)) c -> IR.PointCtx (compPS a) (realToFrac b) (compPSCO c)
  A2 "LineCtx" (ELit (LFloat a)) b -> IR.LineCtx (realToFrac a) (compPV b)
  A4 "TriangleCtx" a b c d -> IR.TriangleCtx (compCM a) (compPM b) (compPO c) (compPV d)
  x -> error $ "compRC " ++ ppShow x

compPSCO x = case x of
  A0 "LowerLeft" -> IR.LowerLeft
  A0 "UpperLeft" -> IR.UpperLeft
  x -> error $ "compPSCO " ++ ppShow x

compCM x = case x of
  A0 "CullNone" -> IR.CullNone
  A1 "CullFront" a -> IR.CullFront $ compFF a
  A1 "CullBack" a -> IR.CullBack $ compFF a
  x -> error $ "compCM " ++ ppShow x

compFF x = case x of
  A0 "CW" -> IR.CW
  A0 "CCW" -> IR.CCW
  x -> error $ "compFF " ++ ppShow x

compPM x = case x of
  A0 "PolygonFill" -> IR.PolygonFill
  A1 "PolygonLine" (ELit (LFloat a)) -> IR.PolygonLine $ realToFrac a
  A1 "PolygonPoint" a  -> IR.PolygonPoint $ compPS a
  x -> error $ "compPM " ++ ppShow x

compPS x = case x of
  A1 "PointSize" (ELit (LFloat a)) -> IR.PointSize $ realToFrac a
  A0 "ProgramPointSize" -> IR.ProgramPointSize
  x -> error $ "compPS " ++ ppShow x

compPO x = case x of
  A2 "Offset" (ELit (LFloat a)) (ELit (LFloat b)) -> IR.Offset (realToFrac a) (realToFrac b)
  A0 "NoOffset" -> IR.NoOffset
  x -> error $ "compPO " ++ ppShow x

compPV x = case x of
    A0 "FirstVertex" -> IR.FirstVertex
    A0 "LastVertex" -> IR.LastVertex
    x -> error $ "compPV " ++ ppShow x
