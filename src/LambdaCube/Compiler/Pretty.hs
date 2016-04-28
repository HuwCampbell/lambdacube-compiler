{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveFoldable #-}
module LambdaCube.Compiler.Pretty
    ( module LambdaCube.Compiler.Pretty
    ) where

import Data.Monoid
import Data.String
--import qualified Data.Set as Set
--import qualified Data.Map as Map
import Control.Monad.Reader
import Control.Monad.State
--import Control.Arrow hiding ((<+>))
--import Debug.Trace

import qualified Text.PrettyPrint.ANSI.Leijen as P

import LambdaCube.Compiler.Utils

-------------------------------------------------------------------------------- inherited doc operations

-- add wl-pprint combinators as necessary here
data DocOp a
    = DOColor Color a
    | DOHSep a a
    | DOHCat a a
    | DOSoftSep a a
    | DOVCat a a
    | DONest Int a
    | DOTupled [a]
    deriving (Eq, Functor, Foldable, Traversable)

data Color = Green | Blue | Underlined
    deriving (Eq)

interpretDocOp :: DocOp P.Doc -> P.Doc
interpretDocOp = \case
    DOHSep a b  -> a P.<+> b
    DOHCat a b  -> a <> b
    DOSoftSep a b -> a P.</> b
    DOVCat a b  -> a P.<$$> b
    DONest n a  -> P.nest n a
    DOTupled a  -> P.tupled a
    DOColor c x -> case c of
        Green       -> P.dullgreen x
        Blue        -> P.dullblue  x
        Underlined  -> P.underline x

-------------------------------------------------------------------------------- fixity

data Fixity
    = Infix  !Int
    | InfixL !Int
    | InfixR !Int
    deriving (Eq, Show)

precedence, leftPrecedence, rightPrecedence :: Fixity -> Int

precedence = \case
    Infix i  -> i
    InfixR i -> i
    InfixL i -> i

leftPrecedence (InfixL i) = i
leftPrecedence f = precedence f + 1

rightPrecedence (InfixR i) = i
rightPrecedence f = precedence f + 1

-------------------------------------------------------------------------------- doc data type

data Doc
    = DDoc (DocOp Doc)

    | DAtom DocAtom
    | DOp String Fixity Doc Doc

    | DFreshName Bool{-used-} Doc
    | DVar Int
    | DUp Int Doc
    deriving (Eq)

data DocAtom
    = SimpleAtom String
    | ComplexAtom String Int Doc DocAtom
    deriving (Eq)

instance IsString Doc where
    fromString = text

text = DAtom . SimpleAtom

instance Monoid Doc where
    mempty = text ""
    a `mappend` b = DDoc $ DOHCat a b

pattern DColor c a = DDoc (DOColor c a)

strip = \case
    DColor _ x     -> strip x
    DUp _ x        -> strip x
    DFreshName _ x -> strip x
    x              -> x

simple x = case strip x of
    DAtom{} -> True
    DVar{} -> True
    _ -> False

renderDoc :: Doc -> P.Doc
renderDoc = render . addPar (-10) . flip runReader [] . flip evalStateT (flip (:) <$> iterate ('\'':) "" <*> ['a'..'z']) . showVars
  where
    showVars x = case x of
        DAtom s -> DAtom <$> showVarA s
        DDoc d -> DDoc <$> traverse showVars d
        DOp s pr x y -> DOp s pr <$> showVars x <*> showVars y
        DVar i -> asks $ text . lookupVarName i
        DFreshName True x -> gets head >>= \n -> modify tail >> local (n:) (showVars x)
        DFreshName False x -> local ("_":) $ showVars x
        DUp i x -> local (dropNth i) $ showVars x
      where
        showVarA (SimpleAtom s) = pure $ SimpleAtom s
        showVarA (ComplexAtom s i d a) = ComplexAtom s i <$> showVars d <*> showVarA a

        lookupVarName i xs | i < length xs = xs !! i
        lookupVarName i _ = ((\s n -> n: '_': s) <$> iterate ('\'':) "" <*> ['a'..'z']) !! i

    addPar :: Int -> Doc -> Doc
    addPar pr x = case x of
        DAtom x -> DAtom $ addParA x
        DOp s pr' x y -> paren $ DOp s pr' (addPar (leftPrecedence pr') x) (addPar (rightPrecedence pr') y)
        DColor c x -> DColor c $ addPar pr x
        DDoc d -> DDoc $ addPar (-10) <$> d
      where
        addParA (SimpleAtom s) = SimpleAtom s
        addParA (ComplexAtom s i d a) = ComplexAtom s i (addPar i d) $ addParA a

        paren = if protect then DParen else id
          where
            protect = case x of
                DOp _ f _ _ -> precedence f < pr
                _ -> False

    render x = case x of
        DDoc d -> interpretDocOp $ render <$> d
        DAtom x -> renderA x
        DOp s _ x y -> case s of
            ""  -> render x P.<> render y
            " " -> render x P.<+> render y
            _ | simple x && simple y && s /= "," -> render x <> P.text s <> render y
              | otherwise -> (render x <++> s) P.<+> render y
      where
        renderA (SimpleAtom s) = P.text s
        renderA (ComplexAtom s _ d a) = P.text s <> render d <> renderA a

        x <++> "," = x <> P.text ","
        x <++> s = x P.<+> P.text s
        
instance Show Doc where
    show = show . renderDoc

-------------------------------------------------------------------------- combinators

hsep [] = mempty
hsep xs = foldr1 (<+>) xs
vcat [] = mempty
vcat xs = foldr1 (<$$>) xs

shVar = DVar

shLet i a b = shLam' (shLet' (inBlue' $ shVar i) $ DUp i a) (DUp i b)
shLet_ a b = DFreshName True $ shLam' (shLet' (shVar 0) $ DUp 0 a) b

inGreen' = DColor Green
inBlue' = DColor Blue
epar = DColor Underlined

a <+> b = DDoc $ DOHSep a b
a </> b = DDoc $ DOSoftSep a b
a <$$> b = DDoc $ DOVCat a b
nest n = DDoc . DONest n
tupled = DDoc . DOTupled

pattern DPar l d r = DAtom (ComplexAtom l (-20) d (SimpleAtom r))
pattern DParen x = DPar "(" x ")"
pattern DBrace x = DPar "{" x "}"
pattern DSep p a b = DOp " " p a b
pattern DGlue p a b = DOp "" p a b

pattern DArr x y = DOp "->" (InfixR (-1)) x y
pattern DAnn x y = DOp ":" (InfixR (-3)) x y
pattern DApp x y = DSep (InfixL 10) x y
pattern DGlueR pr x y = DSep (InfixR pr) x y

braces = DBrace
parens = DParen

shTuple [] = "()"
shTuple [x] = DParen $ DParen x
shTuple xs = DParen $ foldr1 (DOp "," (InfixR (-20))) xs

shAnn _ True x y | strip y == "Type" = x
shAnn s _ x y = DOp s (InfixR (-3)) x y

shArr = DArr

shCstr = DOp "~" (Infix (-2))

shLet' = DOp ":=" (Infix (-4))

pattern DLam vs e = DGlueR (-10) (DAtom (ComplexAtom "\\" 11 vs (SimpleAtom " ->"))) e

hardSpace = DSep (InfixR 11)
dLam vs e = DLam (foldr1 hardSpace vs) e

shLam' x (DFreshName True d) = DFreshName True $ shLam' (DUp 0 x) d
shLam' x (DLam xs y) = DLam (hardSpace x xs) y
shLam' x y = dLam [x] y


--------------------------------------------------------------------------------

class PShow a where
    pShow :: a -> Doc

ppShow = show . pShow

--------------------------------------------------------------------------------

instance PShow Bool where
    pShow b = if b then "True" else "False"

instance (PShow a, PShow b) => PShow (a, b) where
    pShow (a, b) = tupled [pShow a, pShow b]

instance (PShow a, PShow b, PShow c) => PShow (a, b, c) where
    pShow (a, b, c) = tupled [pShow a, pShow b, pShow c]

instance PShow a => PShow [a] where
--    pShow = P.brackets . P.sep . P.punctuate P.comma . map pShow  -- TODO

instance PShow a => PShow (Maybe a) where
    pShow = maybe "Nothing" (("Just" `DApp`) . pShow)

--instance PShow a => PShow (Set a) where
--    pShow = pShow . Set.toList

--instance (PShow s, PShow a) => PShow (Map s a) where
--    pShow = braces . vcat . map (\(k, t) -> pShow k <> P.colon <+> pShow t) . Map.toList

instance (PShow a, PShow b) => PShow (Either a b) where
   pShow = either (("Left" `DApp`) . pShow) (("Right" `DApp`) . pShow)

instance PShow Doc where
    pShow x = x

instance PShow Int     where pShow = fromString . show
instance PShow Integer where pShow = fromString . show
instance PShow Double  where pShow = fromString . show
instance PShow Char    where pShow = fromString . show
instance PShow ()      where pShow _ = "()"


---------------------------------------------------------------------------------
-- TODO: remove

pattern ESC a b <- (splitESC -> Just (a, b)) where ESC a b | 'm' `notElem` a = "\ESC[" ++ a ++ "m" ++ b

splitESC ('\ESC':'[': (span (/='m') -> (a, c: b))) | c == 'm' = Just (a, b)
splitESC _ = Nothing

removeEscs :: String -> String
removeEscs (ESC _ cs) = removeEscs cs
removeEscs (c: cs) = c: removeEscs cs
removeEscs [] = []


