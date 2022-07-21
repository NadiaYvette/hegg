{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
-- {-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE UndecidableInstances #-} -- tmp show
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
module Data.Equality.Graph
    ( module Data.Equality.Graph
    , module Data.Equality.Graph.Classes
    , module Data.Equality.Graph.Nodes
    , module Data.Equality.Language
    , modify, get
    ) where

-- import GHC.Conc

import Data.Function

import Data.Functor.Classes

import Control.Monad
import Control.Monad.State.Strict

import qualified Data.List   as L
import qualified Data.Set    as S

import Data.Equality.Utils
import Data.Equality.Graph.ReprUnionFind
import Data.Equality.Graph.Classes
import Data.Equality.Graph.Nodes
import Data.Equality.Language
import Data.Equality.Graph.Lens
import qualified Data.Equality.Graph.Memo as M
import qualified Data.Equality.Graph.ClassList as CL

-- | E-graph stateful computation
type EGS s = State (EGraph s)

runEGS :: EGraph s -> EGS s a -> (a, EGraph s)
runEGS = flip runState

egraph :: Language l => EGS l a -> EGraph l
egraph = snd . runEGS emptyEGraph

-- | E-graph
--
-- @s@ for the e-node term
-- @nid@ type of e-node ids
data EGraph l = EGraph
    { unionFind :: !ReprUnionFind          -- ^ Union find like structure to find canonical representation of an e-class id
    , classes   :: CL.ClassList l          -- ^ Map canonical e-class ids to their e-classes
    , memo      :: M.Memo l                -- ^ Hashcons maps all canonical e-nodes to their e-class ids
    , worklist  :: Worklist l              -- ^ e-class ids that needs repair and the class it's in
    , analysisWorklist :: Worklist l       -- ^ like 'worklist' but for analysis repairing
    }

type Worklist l = [(ENode 'Canon l, ClassId' 'Canon)]

-- ROMES:TODO: join things built in paralell?
-- instance Ord1 l => Semigroup (EGraph l) where
--     (<>) eg1 eg2 = undefined -- not so easy
-- instance Ord1 l => Monoid (EGraph l) where
--     mempty = EGraph emptyUF mempty mempty mempty

instance (Show (Domain l), Show1 l) => Show (EGraph l) where
    show (EGraph a b c d e) =
        "UnionFind: " <> show a <>
            "\n\nE-Classes: " <> show b <>
                "\n\nHashcons: " <> show c <>
                    "\n\nWorklist: " <> show d <>
                        "\n\nAnalWorklist: " <> show e

-- | Represent an expression (@Fix lang@) in an e-graph
represent :: Language lang => Fix lang -> EGS lang (ClassId' 'Canon)
-- Represent each sub-expression and add the resulting e-node to the e-graph
represent = cata $ sequence >=> add . Node

-- | Add an e-node to the e-graph
--
-- E-node lookup depends on e-node correctly defining equality
add :: forall l k. Language l => ENode k l -> EGS l (ClassId' 'Canon)
add uncanon_e = do
    eg@EGraph { memo = encls } <- get
    let new_en = canonicalize uncanon_e eg
    case M.lookup new_en encls of
      Just canon_enode_id -> return canon_enode_id
      Nothing -> do

        -- Make new equivalence class with a new id in the union-find
        new_eclass_id <- createUnionFindClass

        -- New singleton e-class stores the e-node and its analysis data
        new_eclass <- gets $ \egr -> EClass (fromCanon new_eclass_id) (S.singleton new_en) (makeA new_en egr) []

        -- Update e-classes by going through all e-node children and adding
        -- to the e-class parents the new e-node and its e-class id
        forM_ (children new_en) $ \eclass_id -> do
            modify (_class eclass_id._parents %~ ((new_en, new_eclass_id):))

        -- TODO: From egg: Is this needed?
        -- This is required if we want math pruning to work. Unfortunately, it
        -- also makes the invariants tests x4 slower (because they aren't using
        -- analysis) I think there might be another way to ensure math analysis
        -- pruning to work without having this line here.  Comment it out to
        -- check the result on the unit tests.
        -- 
        -- Update: I found a fix for that case: the modifyA function must add
        -- the parents of the pruned class to the worklist for them to be
        -- upward merged. I think it's a good compromise for requiring the user
        -- to do this. Adding the added node to the worklist everytime creates
        -- too much unnecessary work.
        --
        -- Turns out there are still some bugs without this, and this solves
        -- some of them
        addToWorklist [(new_en, new_eclass_id)]

        -- Add new e-class to existing e-classes
        modifyClasses (CL.insert new_eclass_id new_eclass)

        -- Add the e-node's e-class id at the e-node's id
        modifyMemo (M.insert new_en new_eclass_id)

        -- Modify created node according to analysis
        modify (modifyA new_eclass_id)

        return new_eclass_id


-- | Merge 2 e-classes by id
merge :: forall l k1 k2. Language l => ClassId' k1 -> ClassId' k2 -> EGS l (ClassId' 'Canon)
merge a b = get >>= \egr0 -> do

    -- Use canonical ids
    let
        a' = find a egr0
        b' = find b egr0

    if a' == b'
       then return a'
       else do

           -- Get classes being merged
           let
               class_a = egr0 ^._class a'
               class_b = egr0 ^._class b'

           -- Leader is the class with more parents
           let (leader, leader_class, sub, sub_class) =
                   if length (class_a^._parents) < length (class_b^._parents)
                      then (b', class_b, a', class_a) -- b is leader
                      else (a', class_a, b', class_b) -- a is leader

           new_id <- mergeUnionFindClasses leader sub

           -- Delete subsumed class
           modifyClasses (CL.delete sub)

           -- Add all subsumed parents to worklist
           -- We can do this instead of adding the new e-class itself to the worklist because it'll end up in doing this anyway
           addToWorklist (sub_class^._parents)

           -- Update leader class with all e-nodes and parents from the
           -- subsumed class
           let updatedLeader = leader_class & _parents %~ (<> sub_class^._parents)
                                            & _nodes   %~ (<> sub_class^._nodes)
                                            & _data    .~ new_data
               new_data = joinA @l (leader_class^._data) (sub_class^._data)

           -- If the new_data is different from the classes, the parents of the
           -- class whose data is different from the merged must be put on the
           -- analysisWorklist
           when (new_data /= (leader_class^._data)) $
               addToAnalysisWorklist (leader_class^._parents)
           when (new_data /= (sub_class^._data)) $
               addToAnalysisWorklist (leader_class^._parents)

           -- Update leader so that it has all nodes and parents from
           -- subsumed class
           modify (_class leader .~ updatedLeader)

           -- Subsumed nodes in memo should now point to leader
           --
           -- ROMES:TODO Rebuild should maintain both invariants instead of
           -- merge...
           -- 
           -- I do not understand how they don't have this kind of thing,
           -- Without it, everything breaks
           forM_ (sub_class^._nodes) $ \l ->
               modifyMemo (M.insert l leader)

           modify (modifyA new_id)
           return new_id
            

-- | Canonicalize an E-Node
--
-- Two e-nodes are equal when their canonical form is equal. Canonicalization
-- makes the list of e-class ids the e-node holds a list of canonical ids.
-- Meaning two seemingly different e-nodes might be equal when we figure out
-- that their e-class ids are represented by the same e-class canonical ids
--
-- canonicalize(f(a,b,c,...)) = f((find a), (find b), (find c),...)
canonicalize :: Functor l => ENode k l -> EGraph l -> ENode 'Canon l
canonicalize (Node enode) eg = Node $ fmap (`find` eg) enode

-- | Find the canonical representation of an e-class id in the e-graph
-- Invariant: The e-class id always exists.
find :: ClassId' k -> EGraph l -> ClassId' 'Canon
find cid = unsafeUnpack . findRepr cid . unionFind
    where
        unsafeUnpack Nothing  = error $ "The impossible happened: Couldn't find representation of e-node " <> show cid
        unsafeUnpack (Just x) = x

rebuild :: Language l => EGS l ()
rebuild = do
    -- empty the worklist into a local variable
    wl  <- clearWorkList
    awl <- clearAnalysisWorkList

    -- repair deduplicated eclasses
    forM_ wl repair

    forM_ awl repairAnal

    -- Loop until worklist is completely empty
    wl'  <- gets worklist
    awl' <- gets analysisWorklist
    unless (null wl' && null awl') rebuild

repair :: forall l. Language l => (ENode 'Canon l, ClassId' 'Canon) -> EGS l ()
repair (node, repair_id) = do

    modifyMemo (M.delete node)
    egr <- get
    -- Canonicalize node
    let canon_node = node `canonicalize` egr 

    egrMemo0 <- gets (^._memo)
    case M.insertLookup canon_node (find repair_id egr) egrMemo0 of-- TODO: I seem to really need it. Is find needed? (they don't use it)
      (Nothing, egrMemo1) -> modify (_memo .~ egrMemo1)
      (Just existing_class, egrMemo1) -> do
          modify (_memo .~ egrMemo1)
          _ <- merge existing_class repair_id
          return ()

repairAnal :: forall l. Language l => (ENode 'Canon l, ClassId' 'Canon) -> EGS l ()
repairAnal (node, repair_id) = do

    egr <- get

    let
        canon_id = find repair_id egr
        c        = egr^._class canon_id
        new_data = joinA @l (c^._data) (makeA node egr)

    -- Take action if the new_data is different from the existing data
    when (c^._data /= new_data) $ do
        -- Merge result is different from original class data, update class
        -- with new_data
        put (egr & _class canon_id._data .~ new_data)
        addToAnalysisWorklist (c^._parents)
        modify (modifyA canon_id)



addToWorklist :: Eq1 l => Worklist l -> EGS l ()
addToWorklist li =
    modify (\egr -> egr { worklist = li <> worklist egr})

-- | Clear the e-graph worklist and return the existing work items
clearWorkList :: Eq1 l => EGS l (Worklist l)
clearWorkList = do
    wl <- gets worklist
    modify (\egr -> egr { worklist = mempty })
    return (L.nub wl)

addToAnalysisWorklist :: Eq1 l => Worklist l -> EGS l ()
addToAnalysisWorklist lx =
    modify (\egr -> egr { analysisWorklist = lx <> analysisWorklist egr})

clearAnalysisWorkList :: Eq1 l => EGS l (Worklist l)
clearAnalysisWorkList = do
    wl <- gets analysisWorklist
    modify (\egr -> egr { analysisWorklist = mempty })
    return (L.nub wl)

-- | Get an e-class from an e-graph given its e-class id
--
-- Returns the canonical id of the class and the class itself
--
-- We'll find its canonical representation and then get it from the e-classes map
--
-- Invariant: The e-class exists.
getClass :: ClassId' k -> EGraph s -> (ClassId' 'Canon, EClass s)
getClass cid egr=
    let canon_id = find cid egr
     in (canon_id, classes egr CL.! canon_id)

setClass :: EGraph s -> ClassId' 'Canon -> EClass s -> EGraph s
setClass egr i c = egr { classes = CL.insert i c (classes egr) }

-- | Extend the existing UnionFind equivalence classes with a new one and
-- return the new id
createUnionFindClass :: EGS s (ClassId' 'Canon)
createUnionFindClass = do
    uf <- gets unionFind
    let (new_id, new_uf) = makeNewSet uf
    modify (\egr -> egr { unionFind = new_uf })
    return new_id

-- | Merge two equivalent classes in the union find
mergeUnionFindClasses :: ClassId' 'Canon -> ClassId' 'Canon -> EGS s (ClassId' 'Canon)
mergeUnionFindClasses a b = do
    uf <- gets unionFind
    let (new_id, new_uf) = unionSets a b uf
    modify (\egr -> egr { unionFind = new_uf })
    return new_id


modifyClasses :: (CL.ClassList l -> CL.ClassList l) -> EGS l ()
modifyClasses f = modify (\egr -> egr { classes = f (classes egr) })

modifyMemo :: (M.Memo l -> M.Memo l) -> EGS l ()
modifyMemo f = modify (\egr -> egr { memo = f (memo egr) })

emptyEGraph :: Language l => EGraph l
emptyEGraph = EGraph emptyUF mempty mempty mempty mempty
