{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
module Invariants where

import Test.Tasty
import Test.Tasty.QuickCheck as QC
import Test.Tasty.HUnit

import Control.Monad

import qualified Data.IntMap as IM
import qualified Data.Map as M

import Data.Equality.Graph
import Data.Equality.Saturation
import Sym
import Dot

-- The equivalence relation over e-nodes must be closed over congruence
-- congruenceInvariant :: Testable m (EGraph lang) => Property m


-- The hashcons 𝐻  must map all canonical e-nodes to their e-class ids
--
-- Note: the e-graph argument must have been rebuilt -- checking the property
-- when invariants are broken for sure doesn't make much sense
hashConsInvariant :: forall s. (Show (ENode s), Ord (ENode s), Functor s, Foldable s) => EGraph s -> Bool
hashConsInvariant eg@(EGraph {..}) =
    all f (IM.toList classes)
    where
        -- e-node 𝑛 ∈ 𝑀 [𝑎] ⇐⇒ 𝐻 [canonicalize(𝑛)] = find(𝑎)
        f :: (Ord (ENode s), Functor s) => (ClassId, EClass s) -> Bool
        f (i, EClass _ nodes _) = all g nodes
            where
                g :: (Ord (ENode s), Functor s) => ENode s -> Bool
                g en = case M.lookup (canonicalize en eg) memo of
                    Nothing -> error "how can we not find canonical thing in map? :)" -- False
                    Just i' -> i' == find i eg 

-- ROMES:TODO: Property: Extract expression after equality saturation is always better or equal to the original expression


hciSym :: EGraph ExprF -> Bool
hciSym = hashConsInvariant

instance Arbitrary (EGraph ExprF) where
    arbitrary = sized $ \n -> do
        exps :: [Expr] <- forM [0..n] $ const arbitrary
        -- rws :: [Rewrite ExprF] <- forM [0..n] $ const arbitrary
        (ids, eg) <- return $ runEGS emptyEGraph $
            mapM represent exps
        ids1 <- sublistOf ids
        ids2 <- sublistOf ids
        return $ snd $ runEGS eg $ do
            forM_ (zip ids1 ids2) $ \(a,b) -> do
                merge a b
            rebuild

instance Arbitrary Op where
    arbitrary = oneof [ return Add
                      , return Sub
                      , return Mul
                      , return Div ]

instance Arbitrary Expr where
    arbitrary = sized expr'
        where
            expr' 0 = oneof [ Sym <$> arbitrary
                            , Integer <$> arbitrary
                            ]
            expr' n
              | n > 0 = BinOp <$> arbitrary <*> subexpr <*> subexpr
              where 
                subexpr = expr' (n `div` 2)
            expr' _ = error "size is negative?"

invariants :: TestTree
invariants = testGroup "Invariants"
  [ QC.testProperty "Hash Cons Invariant" hciSym
  ]

-- Test for 
-- equalitySaturation @ExprF @Expr (("a"*(2/2))) ["~g"/"~g" := 1]


-- putStrLn "runEGS emptyEGraph $ reprExpr (("a"*2)/2) >> merge 1 2"
-- putStrLn "runEGS emptyEGraph $ reprExpr (("a"*2)/2+0) >> reprExpr (2/2) >>= \idiv -> reprExpr 1 >>= \i1 -> reprExpr ("a"*1) >>= \imul1 -> reprExpr "a" >>= \ia -> reprExpr ("a"*(2/2)) >>= \i -> merge imul1 ia >> merge 3 i >> merge i1 idiv >> merge 3 5 >> rebuild"
-- putStrLn "compileToQuery (NonVariablePattern (BinOpF Add "z" (NonVariablePattern (IntegerF 0))))"