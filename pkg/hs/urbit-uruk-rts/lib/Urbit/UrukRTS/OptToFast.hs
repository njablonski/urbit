module Urbit.UrukRTS.OptToFast (optToFast) where

import ClassyPrelude    hiding (evaluate, try, fromList)
import System.IO.Unsafe
import Data.Primitive.Array
import Data.Primitive.SmallArray

import Control.Arrow    ((>>>))
import Data.Function    ((&))
import Numeric.Natural  (Natural)
import Numeric.Positive (Positive)
import Prelude          ((!!))

import qualified Urbit.UrukRTS.JetOptimize as O
import qualified Urbit.UrukRTS.Types       as F

--------------------------------------------------------------------------------

optToFast ∷ O.Code → F.Jet
optToFast (O.Code args nm bod exp) = F.Jet{..}
 where
  jArgs = fromIntegral args
  jName = nm
  jBody = bod
  jFast = compile jArgs exp
  jRegs = numReg exp

numReg :: O.Val -> Int
numReg = go 0
 where
  maxi :: [Int] -> Int
  maxi []       = 0
  maxi (x:xs)   = max x (maxi xs)

  go :: Int -> O.Val -> Int
  go acc = \case
    O.ValKal _ vs -> maxi (acc : fmap (go acc) vs)
    O.ValRec _    -> acc
    O.ValRef _ vs -> maxi (acc : fmap (go acc) vs)
    O.ValReg n vs -> maxi (fromIntegral (n+1) : acc : fmap (go acc) vs)
    O.ValIff c t e xs ->
      maxi (acc : go acc c : go acc t : go acc e : fmap (go acc) xs)
    O.ValCas c l r xs ->
      maxi (acc : go acc c : go (acc + 1) l : go (acc + 1) r : fmap (go acc) xs)

{-
    TODO CAS !Int !Exp !Exp !Exp  --  Pattern Match
    TODO VAL (VFun ..)

    TODO Detect undersaturated calls
      CLON !Fun !(SmallArray Exp)    --  Undersaturated call

    TODO Detect fully saturated calls.
      (No AST node for this yet)

    TODO Detect fully saturated calls to jets.
      JETN !Jet !(SmallArray Exp)   --  Fully saturated call
      JET2 !Jet !Exp !Exp           --  Fully saturated call
-}

compile :: Int -> O.Val -> F.Exp
compile arity = go
 where
  go = \case
    O.ValRec xs       -> rec xs
    O.ValRef n []     -> F.REF ((arity - 1) - fromIntegral n)
    O.ValRef n xs     -> F.CALN (F.REF ((arity - 1) - fromIntegral n)) (goArgs xs)
    O.ValReg n []     -> F.REG (fromIntegral n)
    O.ValReg n xs     -> F.CALN (F.REG (fromIntegral n)) (goArgs xs)
    O.ValIff i t e [] -> F.IFF (go i) (go t) (go e)
    O.ValIff i t e xs -> F.CALN (F.IFF (go i) (go t) (go e)) (goArgs xs)

    -- TODO Register Allocation.
    O.ValCas x l r [] -> F.CAS 0 (go x) (go l) (go r)
    O.ValCas x l r xs -> F.CALN (F.CAS 0 (go x) (go l) (go r)) (goArgs xs)
    O.ValKal ur xs    -> kal ur xs

  rec [] = F.SLF
  rec xs =
    --  TODO Optimize for case with no registers.
    let len = length xs
    in  case (compare len arity, xs) of
          (EQ, [x]         ) -> F.REC1 (go x)
          (EQ, [x, y]      ) -> F.REC2 (go x) (go y)
          (EQ, [x, y, z]   ) -> F.REC3 (go x) (go y) (go z)
          (EQ, [x, y, z, p]) -> F.REC4 (go x) (go y) (go z) (go p)
          (EQ, xs          ) -> F.RECN (goArgs xs)
          (LT, xs          ) -> F.CALN F.SLF (goArgs xs) -- TODO
          (GT, xs          ) -> F.CALN F.SLF (goArgs xs) -- TODO

  kal F.Seq     [x, y] = F.SEQ (go x) (go y)
  kal F.Ded     [x]    = F.DED (go x)

  kal F.Uni     []     = F.VAL F.VUni

  kal F.Con     [x, y] = con (go x) (go y)
  kal F.Car     [x]    = F.CAR (go x)
  kal F.Cdr     [x]    = F.CDR (go x)

  kal F.Lef     [x]    = lef (go x)
  kal F.Rit     [x]    = rit (go x)

  kal (F.Nat n) []     = F.VAL (F.VNat n)
  kal (F.Bol b) []     = F.VAL (F.VBol b)

  kal F.Inc     [x]    = F.INC (go x)
  kal F.Dec     [x]    = F.DEC (go x)
  kal F.Fec     [x]    = F.FEC (go x)
  kal F.Zer     [x]    = F.ZER (go x)
  kal F.Eql     [x, y] = F.EQL (go x) (go y)
  kal F.Add     [x, y] = F.ADD (go x) (go y)

  kal F.Lth     [x, y] = F.LTH (go x) (go y)
  kal F.Lsh     [x, y] = F.LSH (go x) (go y)
  kal F.Fub     [x, y] = F.FUB (go x) (go y)
  kal F.Not     [x]    = F.NOT (go x)
  kal F.Xor     [x,y]  = F.XOR (go x) (go y)
  kal F.Div     [x,y]  = F.DIV (go x) (go y)
  kal F.Tra     [x,y]  = F.TRA (go x) (go y)
  kal F.Mod     [x,y]  = F.MOD (go x) (go y)

  kal F.Sub     [x, y] = F.SUB (go x) (go y)
  kal F.Mul     [x, y] = F.MUL (go x) (go y)

  kal f          xs    = F.CALN (rawExp f) (goArgs xs)

  con (F.VAL x) (F.VAL y) = F.VAL (F.VCon x y)
  con x         y         = F.CON x y

  lef (F.VAL x) = F.VAL (F.VLef x)
  lef x         = F.LEF x

  rit (F.VAL x) = F.VAL (F.VRit x)
  rit x         = F.RIT x

  goArgs :: [O.Val] -> SmallArray F.Exp
  goArgs = fromList . fmap go

nodeFun :: F.Node -> F.Fun
nodeFun n = F.Fun (F.nodeArity n) n mempty

rawExp :: F.Node -> F.Exp
rawExp = \case
  F.Nat n -> F.VAL (F.VNat n)
  F.Bol b -> F.VAL (F.VBol b)
  F.Uni   -> F.VAL F.VUni
  n       -> F.VAL (F.VFun (nodeFun n))
