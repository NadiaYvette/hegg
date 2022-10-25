{-# LANGUAGE AllowAmbiguousTypes #-} -- joinA
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-|

E-class analysis, which allows the concise expression of a program analysis over
the e-graph.

An e-class analysis resembles abstract interpretation lifted to the e-graph
level, attaching analysis data from a semilattice to each e-class.

The e-graph maintains and propagates this data as e-classes get merged and new
e-nodes are added.

Analysis data can be used directly to modify the e-graph, to inform how or if
rewrites apply their right-hand sides, or to determine the cost of terms during
the extraction process.

References: https://arxiv.org/pdf/2004.03082.pdf

-}
module Data.Equality.Analysis where

import Data.Kind (Type)
import Control.Arrow ((***))

import Data.Equality.Utils
import Data.Equality.Language
import Data.Equality.Graph.Classes

-- | An e-class analysis with domain @domain@ defined for a language @l@.
--
-- The @domain@ is the type of the domain of the e-class analysis, that is, the
-- type of the data stored in an e-class according to this e-class analysis
class Eq domain => Analysis domain (l :: Type -> Type) where

    -- | When a new e-node is added into a new, singleton e-class, construct a
    -- new value of the domain to be associated with the new e-class, typically
    -- (always?) by accessing the associated data of n's children
    --
    -- The argument is the e-node term populated with its children data
    --
    -- === Example
    --
    -- @
    -- -- domain = Maybe Double
    -- makeA :: Expr (Maybe Double) -> Maybe Double
    -- makeA = \case
    --     BinOp Div e1 e2 -> liftA2 (/) e1 e2
    --     BinOp Sub e1 e2 -> liftA2 (-) e1 e2
    --     BinOp Mul e1 e2 -> liftA2 (*) e1 e2
    --     BinOp Add e1 e2 -> liftA2 (+) e1 e2
    --     Const x -> Just x
    --     Sym _ -> Nothing
    -- @
    makeA :: l domain -> domain

    -- | When e-classes c1 c2 are being merged into c, join d_c1 and
    -- d_c2 into a new value d_c to be associated with the new
    -- e-class c
    joinA :: domain -> domain -> domain

    -- | Optionally modify the e-class c (based on d_c), typically by adding an
    -- e-node to c. Modify should be idempotent if no other changes occur to
    -- the e-class, i.e., modify(modify(c)) = modify(c)
    --
    -- The return value of the modify function is both the modified class and
    -- the expressions (in their fixed-point form) to add to this class. We
    -- can't manually add them because not only would it skip some of the
    -- internal steps of representing + merging, but also because it's
    -- impossible to add any expression with depth > 0 without access to the
    -- e-graph (since we must represent every sub-expression in the e-graph
    -- first).
    --
    -- That's why we must return the modified class and the expressions to add
    -- to this class.
    --
    -- === Example
    --
    -- Pruning an e-class with a constant value of all its nodes except for the
    -- leaf values, and adding a constant value node
    --
    -- @
    --  -- Prune all except leaf e-nodes
    --  modifyA cl =
    --    case cl^._data of
    --      Nothing -> (cl, [])
    --      Just d -> ((_nodes %~ S.filter (F.null .unNode)) cl, [Fix (Const d)])
    -- @
    modifyA :: EClass domain l -> (EClass domain l, [Fix l])
    modifyA c = (c, [])
    {-# INLINE modifyA #-}


-- | The simplest analysis that defines the domain to be () and does nothing
-- otherwise
instance forall l. Analysis () l where
  makeA _ = ()
  joinA = (<>)


-- This instance is only well behaved for any two analysis, where 'modifyA' is
-- called @m1@ and @m2@ respectively, if @m1@ and @m2@ commute.
--
-- That is, @m1@ and @m2@ must satisfy the following law:
-- @
-- m1 . m2 = m2 . m1
-- @
--
-- Here is a simple criterion that should suffice though. If:
--  * The modify function only depends on the analysis value, and
--  * The modify function doesn't change the analysis value
-- Then any two such functions commute.
instance (Language l, Analysis a l, Analysis b l) => Analysis (a, b) l where

  makeA :: l (a, b) -> (a, b)
  makeA g = (makeA @a (fst <$> g), makeA @b (snd <$> g))

  joinA :: (a,b) -> (a,b) -> (a,b)
  joinA (x,y) = joinA @a @l x *** joinA @b @l y

  modifyA :: EClass (a, b) l -> (EClass (a, b) l, [Fix l])
  modifyA c =
    let (ca, la) = modifyA @a (c { eClassData = fst (eClassData c) })
        (cb, lb) = modifyA @b (c { eClassData = snd (eClassData c) })
     in ( EClass (eClassId c) (eClassNodes ca <> eClassNodes cb) (eClassData ca, eClassData cb) (eClassParents ca <> eClassParents cb)
        , la <> lb
        )
