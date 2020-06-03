------------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.CFG.Generator
-- Description      : Provides a monadic interface for constructing Crucible
--                    control flow graphs.
-- Copyright        : (c) Galois, Inc 2014-2018
-- License          : BSD3
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- This module provides a monadic interface for constructing control flow
-- graph expressions.  The goal is to make it easy to convert languages
-- into CFGs.
--
-- The CFGs generated by this interface are similar to, but not quite
-- the same as, the CFGs defined in "Lang.Crucible.CFG.Core". The
-- module "Lang.Crucible.CFG.SSAConversion" contains code that
-- converts the CFGs produced by this interface into Core CFGs in SSA
-- form.
------------------------------------------------------------------------
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
module Lang.Crucible.CFG.Generator
  ( -- * Generator
    Generator
  , FunctionDef
  , defineFunction
    -- * Positions
  , getPosition
  , setPosition
  , withPosition
    -- * References
  , newReference
  , readReference
  , writeReference
    -- * Expressions and statements
  , newReg
  , newUnassignedReg
  , readReg
  , assignReg
  , modifyReg
  , modifyRegM
  , readGlobal
  , writeGlobal

  , newRef
  , newEmptyRef
  , readRef
  , writeRef
  , dropRef
  , call
  , assertExpr
  , assumeExpr
  , addPrintStmt
  , addBreakpointStmt
  , extensionStmt
  , mkAtom
  , forceEvaluation
    -- * Labels
  , newLabel
  , newLambdaLabel
  , newLambdaLabel'
  , currentBlockID
    -- * Block-terminating statements
    -- $termstmt
  , jump
  , jumpToLambda
  , branch
  , returnFromFunction
  , reportError
  , branchMaybe
  , branchVariant
  , tailCall
    -- * Defining blocks
    -- $define
  , defineBlock
  , defineLambdaBlock
  , defineBlockLabel
  , recordCFG
    -- * Control-flow combinators
  , continue
  , continueLambda
  , whenCond
  , unlessCond
  , ifte
  , ifte_
  , ifteM
  , MatchMaybe(..)
  , caseMaybe
  , caseMaybe_
  , fromJustExpr
  , assertedJustExpr
  , while
  -- * Re-exports
  , Ctx.Ctx(..)
  , Position
  , module Lang.Crucible.CFG.Reg
  ) where

import           Control.Lens hiding (Index)
import qualified Control.Monad.Fail as F
import           Control.Monad.State.Strict
import qualified Data.Foldable as Fold
import           Data.Kind
import           Data.Parameterized.Context as Ctx
import           Data.Parameterized.Nonce
import           Data.Parameterized.Some
import           Data.Parameterized.TraversableFC
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import           Data.Text (Text)
import           Data.Void

import           What4.ProgramLoc

import           Lang.Crucible.CFG.Core (AnyCFG(..))
import           Lang.Crucible.CFG.Expr(App(..))
import           Lang.Crucible.CFG.Extension
import           Lang.Crucible.CFG.Reg
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.Types
import           Lang.Crucible.Utils.StateContT

------------------------------------------------------------------------
-- CurrentBlockState

-- | A sequence of statements.
type StmtSeq ext s = Seq (Posd (Stmt ext s))

-- | Information about block being generated in Generator.
data CurrentBlockState ext s
   = CBS { -- | Identifier for current block
           cbsBlockID       :: !(BlockID s)
         , cbsInputValues   :: !(ValueSet s)
         , _cbsStmts        :: !(StmtSeq ext s)
         }

initCurrentBlockState :: ValueSet s -> BlockID s -> CurrentBlockState ext s
initCurrentBlockState inputs block_id =
  CBS { cbsBlockID     = block_id
      , cbsInputValues = inputs
      , _cbsStmts      = Seq.empty
      }

-- | Statements translated so far in this block.
cbsStmts :: Simple Lens (CurrentBlockState ext s) (StmtSeq ext s)
cbsStmts = lens _cbsStmts (\s v -> s { _cbsStmts = v })

------------------------------------------------------------------------
-- GeneratorState

-- | State for translating within a basic block.
data IxGeneratorState ext s (t :: Type -> Type) ret m i
  = GS { _gsEntryLabel :: !(Label s)
       , _gsBlocks    :: !(Seq (Block ext s ret))
       , _gsNonceGen  :: !(NonceGenerator m s)
       , _gsCurrent   :: !i
       , _gsPosition  :: !Position
       , _gsState     :: !(t s)
       , _seenFunctions :: ![AnyCFG ext]
       }

type GeneratorState ext s t ret m =
  IxGeneratorState ext s t ret m (CurrentBlockState ext s)

type EndState ext s t ret m =
  IxGeneratorState ext s t ret m ()

-- | Label for entry block.
gsEntryLabel :: Getter (IxGeneratorState ext s t ret m i) (Label s)
gsEntryLabel = to _gsEntryLabel

-- | List of previously processed blocks.
gsBlocks :: Simple Lens (IxGeneratorState ext s t ret m i) (Seq (Block ext s ret))
gsBlocks = lens _gsBlocks (\s v -> s { _gsBlocks = v })

gsNonceGen :: Getter (IxGeneratorState ext s t ret m i) (NonceGenerator m s)
gsNonceGen = to _gsNonceGen

-- | Information about current block.
gsCurrent :: Lens (IxGeneratorState ext s t ret m i) (IxGeneratorState ext s t ret m j) i j
gsCurrent = lens _gsCurrent (\s v -> s { _gsCurrent = v })

-- | Current source position.
gsPosition :: Simple Lens (IxGeneratorState ext s t ret m i) Position
gsPosition = lens _gsPosition (\s v -> s { _gsPosition = v })

-- | User state for current block. This gets reset between blocks.
gsState :: Simple Lens (IxGeneratorState ext s t ret m i) (t s)
gsState = lens _gsState (\s v -> s { _gsState = v })

-- | List of functions seen by current generator.
seenFunctions :: Simple Lens (IxGeneratorState ext s t ret m i) [AnyCFG ext]
seenFunctions = lens _seenFunctions (\s v -> s { _seenFunctions = v })

------------------------------------------------------------------------

startBlock ::
  BlockID s ->
  EndState ext s t ret m ->
  GeneratorState ext s t ret m
startBlock l gs =
  gs & gsCurrent .~ initCurrentBlockState Set.empty l

-- | Define the current block by defining the position and final
-- statement.
terminateBlock ::
  IsSyntaxExtension ext =>
  TermStmt s ret ->
  GeneratorState ext s t ret m ->
  EndState ext s t ret m
terminateBlock term gs =
  do let p = gs^.gsPosition
     let cbs = gs^.gsCurrent
     -- Define block
     let b = mkBlock (cbsBlockID cbs) (cbsInputValues cbs) (cbs^.cbsStmts) (Posd p term)
     -- Store block
     let gs' = gs & gsCurrent .~ ()
                  & gsBlocks  %~ (Seq.|> b)
     seq b gs'

------------------------------------------------------------------------
-- Generator

-- | A generator is used for constructing a CFG from a sequence of
-- monadic actions.
--
-- The 'ext' parameter indicates the syntax extension.
-- The 's' parameter is the phantom parameter for CFGs.
-- The 't' parameter is the parameterized type that allows user-defined
-- state.
-- The 'ret' parameter is the return type of the CFG.
-- The 'm' parameter is a monad over which the generator is lifted
-- The 'a' parameter is the value returned by the monad.

newtype Generator ext s (t :: Type -> Type) (ret :: CrucibleType) m a
      = Generator { unGenerator :: StateContT (GeneratorState ext s t ret m)
                                              (EndState ext s t ret m)
                                              m
                                              a
                  }
  deriving ( Functor
           , Applicative
           )

instance MonadTrans (Generator ext s t ret) where
  lift m = Generator (lift m)

instance Monad m => Monad (Generator ext s t ret m) where
  return  = Generator . return
  x >>= f = Generator (unGenerator x >>= unGenerator . f)
#if !MIN_VERSION_base(4,13,0)
  fail msg = Generator $ do
     p <- use gsPosition
     fail $ unwords [ "Failure encountered while generating a Crucible CFG:"
                    , "at " ++ show p ++ ": " ++ msg
                    ]
#endif

instance F.MonadFail m => F.MonadFail (Generator ext s t ret m) where
  fail msg = Generator $ do
     p <- use gsPosition
     fail $ unwords [ "Failure encountered while generating a Crucible CFG:"
                    , "at " ++ show p ++ ": " ++ msg
                    ]

instance Monad m => MonadState (t s) (Generator ext s t ret m) where
  get = Generator $ use gsState
  put v = Generator $ gsState .= v

-- This function only works for 'Generator' actions that terminate
-- early, i.e. do not call their continuation. This includes actions
-- that end with block-terminating statements defined with
-- 'terminateEarly'.
runGenerator ::
  Generator ext s t ret m Void ->
  GeneratorState ext s t ret m ->
  m (EndState ext s t ret m)
runGenerator m gs = runStateContT (unGenerator m) absurd gs

-- | Get the current position.
getPosition :: Generator ext s t ret m Position
getPosition = Generator $ use gsPosition

-- | Set the current position.
setPosition :: Position -> Generator ext s t ret m ()
setPosition p = Generator $ gsPosition .= p

-- | Set the current position temporarily, and reset it afterwards.
withPosition :: Monad m
             => Position
             -> Generator ext s t ret m a
             -> Generator ext s t ret m a
withPosition p m =
  do old_pos <- getPosition
     setPosition p
     v <- m
     setPosition old_pos
     return v

mkNonce :: Monad m => Generator ext s t ret m (Nonce s tp)
mkNonce =
  do ng <- Generator $ use gsNonceGen
     Generator $ lift $ freshNonce ng

----------------------------------------------------------------------
-- Expressions and statements

addStmt :: Monad m => Stmt ext s -> Generator ext s t ret m ()
addStmt s =
  do p <- getPosition
     cbs <- Generator $ use gsCurrent
     let ps = Posd p s
     let cbs' = cbs & cbsStmts %~ (Seq.|> ps)
     seq ps $ seq cbs' $ Generator $ gsCurrent .= cbs'

freshAtom :: (Monad m, IsSyntaxExtension ext) => AtomValue ext s tp -> Generator ext s t ret m (Atom s tp)
freshAtom av =
  do p <- getPosition
     n <- mkNonce
     let atom = Atom { atomPosition = p
                     , atomId = n
                     , atomSource = Assigned
                     , typeOfAtom = typeOfAtomValue av
                     }
     addStmt (DefineAtom atom av)
     return atom

-- | Create an atom equivalent to the given expression if it is
-- not already an 'AtomExpr'.
mkAtom :: (Monad m, IsSyntaxExtension ext) => Expr ext s tp -> Generator ext s t ret m (Atom s tp)
mkAtom (AtomExpr a)   = return a
mkAtom (App a)        = freshAtom . EvalApp =<< traverseFC mkAtom a

-- | Create a new reference bound to the value of the expression
newReference :: (Monad m, IsSyntaxExtension ext) => Expr ext s tp -> Generator ext s t ret m (Expr ext s (ReferenceType tp))
newReference e = do a <- mkAtom e
                    AtomExpr <$> freshAtom (NewRef a)

readReference :: (Monad m, IsSyntaxExtension ext) => Expr ext s (ReferenceType tp) -> Generator ext s t ret m (Expr ext s tp)
readReference ref = do a <- mkAtom ref
                       AtomExpr <$> freshAtom (ReadRef a)

writeReference :: (Monad m, IsSyntaxExtension ext) => Expr ext s (ReferenceType tp) -> Expr ext s tp -> Generator ext s t ret m ()
writeReference ref val = do aref <- mkAtom ref
                            aval <- mkAtom val
                            undefined -- Generator $ addStmt $ WriteRef aref aval

-- | Read a global variable.
readGlobal :: (Monad m, IsSyntaxExtension ext) => GlobalVar tp -> Generator ext s t ret m (Expr ext s tp)
readGlobal v = AtomExpr <$> freshAtom (ReadGlobal v)

-- | Write to a global variable.
writeGlobal :: (Monad m, IsSyntaxExtension ext) => GlobalVar tp -> Expr ext s tp -> Generator ext s t ret m ()
writeGlobal v e =
  do a <- mkAtom e
     addStmt (WriteGlobal v a)

-- | Read the current value of a reference cell.
readRef :: (Monad m, IsSyntaxExtension ext) => Expr ext s (ReferenceType tp) -> Generator ext s t ret m (Expr ext s tp)
readRef ref =
  do r <- mkAtom ref
     AtomExpr <$> freshAtom (ReadRef r)

-- | Write the given value into the reference cell.
writeRef :: (Monad m, IsSyntaxExtension ext) => Expr ext s (ReferenceType tp) -> Expr ext s tp -> Generator ext s t ret m ()
writeRef ref val =
  do r <- mkAtom ref
     v <- mkAtom val
     addStmt (WriteRef r v)

-- | Deallocate the given reference cell, returning it to an uninialized state.
--   The reference cell can still be used; subsequent writes will succeed,
--   and reads will succeed if some value is written first.
dropRef :: (Monad m, IsSyntaxExtension ext) => Expr ext s (ReferenceType tp) -> Generator ext s t ret m ()
dropRef ref =
  do r <- mkAtom ref
     addStmt (DropRef r)

-- | Generate a new reference cell with the given initial contents.
newRef :: (Monad m, IsSyntaxExtension ext) => Expr ext s tp -> Generator ext s t ret m (Expr ext s (ReferenceType tp))
newRef val =
  do v <- mkAtom val
     AtomExpr <$> freshAtom (NewRef v)

-- | Generate a new empty reference cell.  If an unassigned reference is later
--   read, it will generate a runtime error.
newEmptyRef :: (Monad m, IsSyntaxExtension ext) => TypeRepr tp -> Generator ext s t ret m (Expr ext s (ReferenceType tp))
newEmptyRef tp =
  AtomExpr <$> freshAtom (NewEmptyRef tp)

-- | Generate a new virtual register with the given initial value.
newReg :: (Monad m, IsSyntaxExtension ext) => Expr ext s tp -> Generator ext s t ret m (Reg s tp)
newReg e =
  do r <- newUnassignedReg (exprType e)
     assignReg r e
     return r

-- | Produce a new virtual register without giving it an initial value.
--   NOTE! If you fail to initialize this register with a subsequent
--   call to @assignReg@, errors will arise during SSA conversion.
newUnassignedReg :: Monad m => TypeRepr tp -> Generator ext s t ret m (Reg s tp)
newUnassignedReg tp =
  do p <- getPosition
     n <- mkNonce
     return $! Reg { regPosition = p
                   , regId = n
                   , typeOfReg = tp
                   }

-- | Get the current value of a register.
readReg :: (Monad m, IsSyntaxExtension ext) => Reg s tp -> Generator ext s t ret m (Expr ext s tp)
readReg r = AtomExpr <$> freshAtom (ReadReg r)

-- | Update the value of a register.
assignReg :: (Monad m, IsSyntaxExtension ext) => Reg s tp -> Expr ext s tp -> Generator ext s t ret m ()
assignReg r e =
  do a <- mkAtom e
     addStmt (SetReg r a)

-- | Modify the value of a register.
modifyReg :: (Monad m, IsSyntaxExtension ext) => Reg s tp -> (Expr ext s tp -> Expr ext s tp) -> Generator ext s t ret m ()
modifyReg r f =
  do v <- readReg r
     assignReg r $! f v

-- | Modify the value of a register.
modifyRegM :: (Monad m, IsSyntaxExtension ext)
           => Reg s tp
           -> (Expr ext s tp -> Generator ext s t ret m (Expr ext s tp))
           -> Generator ext s t ret m ()
modifyRegM r f =
  do v <- readReg r
     v' <- f v
     assignReg r v'

-- | Add a statement to print a value.
addPrintStmt :: (Monad m, IsSyntaxExtension ext) => Expr ext s (StringType Unicode) -> Generator ext s t ret m ()
addPrintStmt e =
  do e_a <- mkAtom e
     addStmt (Print e_a)

-- | Add a breakpoint.
addBreakpointStmt ::
  (Monad m, IsSyntaxExtension ext) =>
  Text {- ^ breakpoint name -} ->
  Assignment (Value s) args {- ^ breakpoint values -} ->
  Generator ext s t r m ()
addBreakpointStmt nm args = addStmt $ Breakpoint (BreakpointName nm) args

-- | Add an assert statement.
assertExpr ::
  (Monad m, IsSyntaxExtension ext) =>
  Expr ext s BoolType {- ^ assertion -} ->
  Expr ext s (StringType Unicode) {- ^ error message -} ->
  Generator ext s t ret m ()
assertExpr b e =
  do b_a <- mkAtom b
     e_a <- mkAtom e
     addStmt (Assert b_a e_a)

-- | Add an assume statement.
assumeExpr ::
  (Monad m, IsSyntaxExtension ext) =>
  Expr ext s BoolType {- ^ assumption -} ->
  Expr ext s (StringType Unicode) {- ^ reason message -} ->
  Generator ext s t ret m ()
assumeExpr b e =
  do b_a <- mkAtom b
     m_a <- mkAtom e
     addStmt (Assume b_a m_a)


-- | Stash the given CFG away for later retrieval.  This is primarily
--   used when translating inner and anonymous functions in the
--   context of an outer function.
recordCFG :: AnyCFG ext -> Generator ext s t ret m ()
recordCFG g = Generator $ seenFunctions %= (g:)

------------------------------------------------------------------------
-- Labels

-- | Create a new block label.
newLabel :: Monad m => Generator ext s t ret m (Label s)
newLabel = Label <$> mkNonce

-- | Create a new lambda label.
newLambdaLabel :: Monad m => KnownRepr TypeRepr tp => Generator ext s t ret m (LambdaLabel s tp)
newLambdaLabel = newLambdaLabel' knownRepr

-- | Create a new lambda label, using an explicit 'TypeRepr'.
newLambdaLabel' :: Monad m => TypeRepr tp -> Generator ext s t ret m (LambdaLabel s tp)
newLambdaLabel' tpr =
  do p <- getPosition
     idx <- mkNonce
     i <- mkNonce
     let lbl = LambdaLabel idx a
         a = Atom { atomPosition = p
                  , atomId = i
                  , atomSource = LambdaArg lbl
                  , typeOfAtom = tpr
                  }
     return $! lbl

-- | Return the label of the current basic block.
currentBlockID :: Generator ext s t ret m (BlockID s)
currentBlockID =
  Generator $
  (\st -> st ^. gsCurrent & cbsBlockID) <$> get

----------------------------------------------------------------------
-- Defining blocks

-- $define The block-defining commands should be used with a
-- 'Generator' action ending with a block-terminating statement, which
-- gives it a polymorphic type.

-- | End the translation of the current block, and then continue
-- generating a new block with the given label.
continue ::
  (Monad m, IsSyntaxExtension ext) =>
  Label s {- ^ label for new block -} ->
  (forall a. Generator ext s t ret m a) {- ^ action to end current block -} ->
  Generator ext s t ret m ()
continue lbl action =
  Generator $ StateContT $ \cont gs ->
  do gs' <- runGenerator action gs
     cont () (startBlock (LabelID lbl) gs')

-- | End the translation of the current block, and then continue
-- generating a new lambda block with the given label. The return
-- value is the argument to the lambda block.
continueLambda ::
  (Monad m, IsSyntaxExtension ext) =>
  LambdaLabel s tp {- ^ label for new block -} ->
  (forall a. Generator ext s t ret m a) {- ^ action to end current block -} ->
  Generator ext s t ret m (Expr ext s tp)
continueLambda lbl action =
  Generator $ StateContT $ \cont gs ->
  do gs' <- runGenerator action gs
     cont (AtomExpr (lambdaAtom lbl)) (startBlock (LambdaID lbl) gs')

defineSomeBlock ::
  (Monad m, IsSyntaxExtension ext) =>
  BlockID s ->
  Generator ext s t ret m Void ->
  Generator ext s t ret m ()
defineSomeBlock l next =
  Generator $ StateContT $ \cont gs0 ->
  do let gs1 = startBlock l (gs0 & gsCurrent .~ ())
     gs2 <- runGenerator next gs1
     -- Reset current block and state.
     let gs3 = gs2 & gsPosition .~ gs0^.gsPosition
                   & gsCurrent .~ gs0^.gsCurrent
     cont () gs3

-- | Define a block with an ordinary label.
defineBlock ::
  (Monad m, IsSyntaxExtension ext) =>
  Label s ->
  (forall a. Generator ext s t ret m a) ->
  Generator ext s t ret m ()
defineBlock l action =
  defineSomeBlock (LabelID l) action

-- | Define a block that has a lambda label.
defineLambdaBlock ::
  (Monad m, IsSyntaxExtension ext) =>
  LambdaLabel s tp ->
  (forall a. Expr ext s tp -> Generator ext s t ret m a) ->
  Generator ext s t ret m ()
defineLambdaBlock l action =
  defineSomeBlock (LambdaID l) (action (AtomExpr (lambdaAtom l)))

-- | Define a block with a fresh label, returning the label.
defineBlockLabel ::
  (Monad m, IsSyntaxExtension ext) =>
  (forall a. Generator ext s t ret m a) ->
  Generator ext s t ret m (Label s)
defineBlockLabel action =
  do l <- newLabel
     defineBlock l action
     return l

------------------------------------------------------------------------
-- Generator interface

-- | Evaluate an expression to an 'AtomExpr', so that it can be reused multiple times later.
forceEvaluation :: (Monad m, IsSyntaxExtension ext) => Expr ext s tp -> Generator ext s t ret m (Expr ext s tp)
forceEvaluation e = AtomExpr <$> mkAtom e

-- | Add a statement from the syntax extension to the current basic block.
extensionStmt ::
   (Monad m, IsSyntaxExtension ext) =>
   StmtExtension ext (Expr ext s) tp ->
   Generator ext s t ret m (Expr ext s tp)
extensionStmt stmt = do
   stmt' <- traverseFC mkAtom stmt
   AtomExpr <$> freshAtom (EvalExt stmt')

-- | Call a function.
call :: (Monad m, IsSyntaxExtension ext)
        => Expr ext s (FunctionHandleType args ret) {- ^ function to call -}
        -> Assignment (Expr ext s) args {- ^ function arguments -}
        -> Generator ext s t r m (Expr ext s ret)
call h args = AtomExpr <$> call' h args

-- | Call a function.
call' :: (Monad m, IsSyntaxExtension ext)
        => Expr ext s (FunctionHandleType args ret)
        -> Assignment (Expr ext s) args
        -> Generator ext s t r m (Atom s ret)
call' h args = do
  case exprType h of
    FunctionHandleRepr _ retType -> do
      h_a <- mkAtom h
      args_a <- traverseFC mkAtom args
      freshAtom $ Call h_a args_a retType

----------------------------------------------------------------------
-- Block-terminating statements

-- $termstmt The following operations produce block-terminating
-- statements, and have early termination behavior in the 'Generator'
-- monad: Like 'fail', they have polymorphic return types and cause
-- any following monadic actions to be skipped.

-- | End the current block with the given terminal statement, and skip
-- the rest of the 'Generator' computation.
terminateEarly ::
  (Monad m, IsSyntaxExtension ext) => TermStmt s ret -> Generator ext s t ret m a
terminateEarly term =
  Generator $ StateContT $ \_cont gs ->
  return (terminateBlock term gs)

-- | Jump to the given label.
jump :: (Monad m, IsSyntaxExtension ext) => Label s -> Generator ext s t ret m a
jump l = terminateEarly (Jump l)

-- | Jump to the given label with output.
jumpToLambda ::
  (Monad m, IsSyntaxExtension ext) =>
  LambdaLabel s tp ->
  Expr ext s tp ->
  Generator ext s t ret m a
jumpToLambda lbl v = do
  v_a <- mkAtom v
  terminateEarly (Output lbl v_a)

-- | Branch between blocks.
branch ::
  (Monad m, IsSyntaxExtension ext) =>
  Expr ext s BoolType {- ^ condition -} ->
  Label s             {- ^ true label -} ->
  Label s             {- ^ false label -} ->
  Generator ext s t ret m a
branch (App (Not e)) x_id y_id = do
  branch e y_id x_id
branch e x_id y_id = do
  a <- mkAtom e
  terminateEarly (Br a x_id y_id)

-- | Return from this function with the given return value.
returnFromFunction ::
  (Monad m, IsSyntaxExtension ext) =>
  Expr ext s ret -> Generator ext s t ret m a
returnFromFunction e = do
  e_a <- mkAtom e
  terminateEarly (Return e_a)

-- | Report an error message.
reportError ::
  (Monad m, IsSyntaxExtension ext) =>
  Expr ext s (StringType Unicode) -> Generator ext s t ret m a
reportError e = do
  e_a <- mkAtom e
  terminateEarly (ErrorStmt e_a)

-- | Branch between blocks based on a @Maybe@ value.
branchMaybe ::
  (Monad m, IsSyntaxExtension ext) =>
  Expr ext s (MaybeType tp) ->
  LambdaLabel s tp {- ^ label for @Just@ -} ->
  Label s          {- ^ label for @Nothing@ -} ->
  Generator ext s t ret m a
branchMaybe v l1 l2 =
  case exprType v of
    MaybeRepr etp ->
      do v_a <- mkAtom v
         terminateEarly (MaybeBranch etp v_a l1 l2)

-- | Switch on a variant value. Examine the tag of the variant and
-- jump to the appropriate switch target.
branchVariant ::
  (Monad m, IsSyntaxExtension ext) =>
  Expr ext s (VariantType varctx) {- ^ value to scrutinize -} ->
  Assignment (LambdaLabel s) varctx {- ^ target labels -} ->
  Generator ext s t ret m a
branchVariant v lbls =
  case exprType v of
    VariantRepr typs ->
      do v_a <- mkAtom v
         terminateEarly (VariantElim typs v_a lbls)

-- | End a block with a tail call to a function.
tailCall ::
  (Monad m, IsSyntaxExtension ext) =>
  Expr ext s (FunctionHandleType args ret) {- ^ function to call -} ->
  Assignment (Expr ext s) args {- ^ function arguments -} ->
  Generator ext s t ret m a
tailCall h args =
  case exprType h of
    FunctionHandleRepr argTypes _retType ->
      do h_a <- mkAtom h
         args_a <- traverseFC mkAtom args
         terminateEarly (TailCall h_a argTypes args_a)

------------------------------------------------------------------------
-- Combinators

-- | Expression-level if-then-else.
ifte :: (Monad m, IsSyntaxExtension ext, KnownRepr TypeRepr tp)
     => Expr ext s BoolType
     -> Generator ext s t ret m (Expr ext s tp) -- ^ true branch
     -> Generator ext s t ret m (Expr ext s tp) -- ^ false branch
     -> Generator ext s t ret m (Expr ext s tp)
ifte e x y = do
  c_id <- newLambdaLabel
  x_id <- defineBlockLabel $ x >>= jumpToLambda c_id
  y_id <- defineBlockLabel $ y >>= jumpToLambda c_id
  continueLambda c_id (branch e x_id y_id)

-- | Statement-level if-then-else.
ifte_ :: (Monad m, IsSyntaxExtension ext)
      => Expr ext s BoolType
      -> Generator ext s t ret m () -- ^ true branch
      -> Generator ext s t ret m () -- ^ false branch
      -> Generator ext s t ret m ()
ifte_ e x y = do
  c_id <- newLabel
  x_id <- defineBlockLabel $ x >> jump c_id
  y_id <- defineBlockLabel $ y >> jump c_id
  continue c_id (branch e x_id y_id)

-- | Expression-level if-then-else with a monadic condition.
ifteM :: (Monad m, IsSyntaxExtension ext, KnownRepr TypeRepr tp)
     => Generator ext s t ret m (Expr ext s BoolType)
     -> Generator ext s t ret m (Expr ext s tp) -- ^ true branch
     -> Generator ext s t ret m (Expr ext s tp) -- ^ false branch
     -> Generator ext s t ret m (Expr ext s tp)
ifteM em x y = do { m <- em; ifte m x y }

-- | Run a computation when a condition is true.
whenCond :: (Monad m, IsSyntaxExtension ext)
         => Expr ext s BoolType
         -> Generator ext s t ret m ()
         -> Generator ext s t ret m ()
whenCond e x = do
  c_id <- newLabel
  t_id <- defineBlockLabel $ x >> jump c_id
  continue c_id (branch e t_id c_id)

-- | Run a computation when a condition is false.
unlessCond :: (Monad m, IsSyntaxExtension ext)
           => Expr ext s BoolType
           -> Generator ext s t ret m ()
           -> Generator ext s t ret m ()
unlessCond e x = do
  c_id <- newLabel
  f_id <- defineBlockLabel $ x >> jump c_id
  continue c_id (branch e c_id f_id)

data MatchMaybe j r
   = MatchMaybe
   { onJust :: j -> r
   , onNothing :: r
   }

-- | Compute an expression by cases over a @Maybe@ value.
caseMaybe :: (Monad m, IsSyntaxExtension ext)
          => Expr ext s (MaybeType tp) {- ^ expression to scrutinize -}
          -> TypeRepr r {- ^ result type -}
          -> MatchMaybe (Expr ext s tp) (Generator ext s t ret m (Expr ext s r)) {- ^ case branches -}
          -> Generator ext s t ret m (Expr ext s r)
caseMaybe v retType cases = do
  let etp = case exprType v of
              MaybeRepr etp' -> etp'
  j_id <- newLambdaLabel' etp
  n_id <- newLabel
  c_id <- newLambdaLabel' retType
  defineLambdaBlock j_id $ onJust cases >=> jumpToLambda c_id
  defineBlock       n_id $ onNothing cases >>= jumpToLambda c_id
  continueLambda c_id (branchMaybe v j_id n_id)

-- | Evaluate different statements by cases over a @Maybe@ value.
caseMaybe_ :: (Monad m, IsSyntaxExtension ext)
           => Expr ext s (MaybeType tp) {- ^ expression to scrutinize -}
           -> MatchMaybe (Expr ext s tp) (Generator ext s t ret m ()) {- ^ case branches -}
           -> Generator ext s t ret m ()
caseMaybe_ v cases = do
  let etp = case exprType v of
              MaybeRepr etp' -> etp'
  j_id <- newLambdaLabel' etp
  n_id <- newLabel
  c_id <- newLabel
  defineLambdaBlock j_id $ \e -> onJust cases e >> jump c_id
  defineBlock       n_id $ onNothing cases >> jump c_id
  continue c_id (branchMaybe v j_id n_id)

-- | Return the argument of a @Just@ value, or call 'reportError' if
-- the value is @Nothing@.
fromJustExpr :: (Monad m, IsSyntaxExtension ext)
             => Expr ext s (MaybeType tp)
             -> Expr ext s (StringType Unicode) {- ^ error message -}
             -> Generator ext s t ret m (Expr ext s tp)
fromJustExpr e msg = do
  let etp = case exprType e of
              MaybeRepr etp' -> etp'
  j_id <- newLambdaLabel' etp
  n_id <- newLabel
  c_id <- newLambdaLabel' etp
  defineLambdaBlock j_id $ jumpToLambda c_id
  defineBlock       n_id $ reportError msg
  continueLambda c_id (branchMaybe e j_id n_id)

-- | This asserts that the value in the expression is a @Just@ value, and
-- returns the underlying value.
assertedJustExpr :: (Monad m, IsSyntaxExtension ext)
                 => Expr ext s (MaybeType tp)
                 -> Expr ext s (StringType Unicode) {- ^ error message -}
                 -> Generator ext s t ret m (Expr ext s tp)
assertedJustExpr e msg =
  case exprType e of
    MaybeRepr tp ->
      forceEvaluation $! App (FromJustValue tp e msg)

-- | Execute the loop body as long as the test condition is true.
while :: (Monad m, IsSyntaxExtension ext)
      => (Position, Generator ext s t ret m (Expr ext s BoolType)) {- ^ test condition -}
      -> (Position, Generator ext s t ret m ()) {- ^ loop body -}
      -> Generator ext s t ret m ()
while (pcond,cond) (pbody,body) = do
  cond_lbl <- newLabel
  loop_lbl <- newLabel
  exit_lbl <- newLabel

  withPosition pcond $
    defineBlock cond_lbl $ do
      b <- cond
      branch b loop_lbl exit_lbl

  withPosition pbody $
    defineBlock loop_lbl $ do
      body
      jump cond_lbl

  continue exit_lbl (jump cond_lbl)

------------------------------------------------------------------------
-- CFG

cfgFromGenerator :: FnHandle init ret
                 -> IxGeneratorState ext s t ret m i
                 -> CFG ext s init ret
cfgFromGenerator h s =
  CFG { cfgHandle = h
      , cfgEntryLabel = s^.gsEntryLabel
      , cfgBlocks = Fold.toList (s^.gsBlocks)
      }

-- | Given the arguments, this returns the initial state, and an action for
-- computing the return value.
type FunctionDef ext t init ret m =
  forall s .
  Assignment (Atom s) init ->
  (t s, Generator ext s t ret m (Expr ext s ret))

-- | The main API for generating CFGs for a Crucible function.
--
--   The given @FunctionDef@ action is run to generate a registerized
--   CFG. The return value of @defineFunction@ is the generated CFG,
--   and a list of CFGs for any other auxiliary function definitions
--   generated along the way (e.g., for anonymous or inner functions).
defineFunction :: (Monad m, IsSyntaxExtension ext)
               => Position                     -- ^ Source position for the function
               -> Some (NonceGenerator m)      -- ^ Nonce generator for internal use
               -> FnHandle init ret            -- ^ Handle for the generated function
               -> FunctionDef ext t init ret m -- ^ Generator action and initial state
               -> m (SomeCFG ext init ret, [AnyCFG ext]) -- ^ Generated CFG and inner function definitions
defineFunction p sng h f = seq h $ do
  let argTypes = handleArgTypes h
  Some ng <- return sng
  inputs <- mkInputAtoms ng p argTypes
  let inputSet = Set.fromList (toListFC (Some . AtomValue) inputs)
  let (init_state, action) = f $! inputs
  lbl <- Label <$> freshNonce ng
  let cbs = initCurrentBlockState inputSet (LabelID lbl)
  let ts = GS { _gsEntryLabel = lbl
              , _gsBlocks = Seq.empty
              , _gsNonceGen = ng
              , _gsCurrent = cbs
              , _gsPosition = p
              , _gsState = init_state
              , _seenFunctions = []
              }
  ts' <- runGenerator (action >>= returnFromFunction) $! ts
  return (SomeCFG (cfgFromGenerator h ts'), ts'^.seenFunctions)
