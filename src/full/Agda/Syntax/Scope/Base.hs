{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GADTs              #-}

{-| This module defines the notion of a scope and operations on scopes.
-}
module Agda.Syntax.Scope.Base where

import Prelude hiding ( null )

import Control.Arrow (first, second)
import Control.Monad

import Data.Either (partitionEithers)
import Data.Function
import qualified Data.List as List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Maybe
import qualified Data.Semigroup as Sgrp

import Data.Data (Data)

import Agda.Benchmarking

import Agda.Syntax.Position
import Agda.Syntax.Common
import Agda.Syntax.Fixity
import Agda.Syntax.Abstract.Name as A
import Agda.Syntax.Concrete.Name as C
import qualified Agda.Syntax.Concrete as C
import Agda.Syntax.Concrete.Fixity as C

import Agda.Utils.AssocList (AssocList)
import qualified Agda.Utils.AssocList as AssocList
import Agda.Utils.Functor
import Agda.Utils.Lens
import Agda.Utils.List
import Agda.Utils.Maybe (filterMaybe)
import Agda.Utils.NonemptyList
import Agda.Utils.Null
import Agda.Utils.Pretty
import Agda.Utils.Singleton
import qualified Agda.Utils.Map as Map

import Agda.Utils.Impossible

-- * Scope representation

-- | A scope is a named collection of names partitioned into public and private
--   names.
data Scope = Scope
      { scopeName           :: A.ModuleName
      , scopeParents        :: [A.ModuleName]
      , scopeNameSpaces     :: ScopeNameSpaces
      , scopeImports        :: Map C.QName A.ModuleName
      , scopeDatatypeModule :: Maybe DataOrRecord
      }
  deriving (Data, Eq, Show)

-- | See 'Agda.Syntax.Common.Access'.
data NameSpaceId
  = PrivateNS        -- ^ Things not exported by this module.
  | PublicNS         -- ^ Things defined and exported by this module.
  | ImportedNS       -- ^ Things from open public, exported by this module.
  | OnlyQualifiedNS  -- ^ Visible (as qualified) from outside,
                     --   but not exported when opening the module.
                     --   Used for qualified constructors.
  deriving (Data, Eq, Bounded, Enum, Show)

allNameSpaces :: [NameSpaceId]
allNameSpaces = [minBound..maxBound]

type ScopeNameSpaces = [(NameSpaceId, NameSpace)]

localNameSpace :: Access -> NameSpaceId
localNameSpace PublicAccess    = PublicNS
localNameSpace PrivateAccess{} = PrivateNS
localNameSpace OnlyQualified   = OnlyQualifiedNS

nameSpaceAccess :: NameSpaceId -> Access
nameSpaceAccess PrivateNS = PrivateAccess Inserted
nameSpaceAccess _         = PublicAccess

-- | Get a 'NameSpace' from 'Scope'.
scopeNameSpace :: NameSpaceId -> Scope -> NameSpace
scopeNameSpace ns = fromMaybe __IMPOSSIBLE__ . lookup ns . scopeNameSpaces

-- | A lens for 'scopeNameSpaces'
updateScopeNameSpaces :: (ScopeNameSpaces -> ScopeNameSpaces) -> Scope -> Scope
updateScopeNameSpaces f s = s { scopeNameSpaces = f (scopeNameSpaces s) }

-- | ``Monadic'' lens (Functor sufficient).
updateScopeNameSpacesM ::
  (Functor m) => (ScopeNameSpaces -> m ScopeNameSpaces) -> Scope -> m Scope
updateScopeNameSpacesM f s = for (f $ scopeNameSpaces s) $ \ x ->
  s { scopeNameSpaces = x }

-- | The complete information about the scope at a particular program point
--   includes the scope stack, the local variables, and the context precedence.
data ScopeInfo = ScopeInfo
      { _scopeCurrent       :: A.ModuleName
      , _scopeModules       :: Map A.ModuleName Scope
      , _scopeVarsToBind    :: LocalVars
      , _scopeLocals        :: LocalVars
      , _scopePrecedence    :: PrecedenceStack
      , _scopeInverseName   :: NameMap
      , _scopeInverseModule :: ModuleMap
      , _scopeInScope       :: InScopeSet
      , _scopeFixities      :: C.Fixities    -- ^ Maps concrete names C.Name to fixities
      , _scopePolarities    :: C.Polarities  -- ^ Maps concrete names C.Name to polarities
      }
  deriving (Data, Show)

type NameMap   = Map A.QName      (NonemptyList C.QName)
type ModuleMap = Map A.ModuleName [C.QName]
-- type ModuleMap = Map A.ModuleName (NonemptyList C.QName)

instance Eq ScopeInfo where
  ScopeInfo c1 m1 v1 l1 p1 _ _ _ _ _ == ScopeInfo c2 m2 v2 l2 p2 _ _ _ _ _ =
    c1 == c2 && m1 == m2 && v1 == v2 && l1 == l2 && p1 == p2

-- | Local variables.
type LocalVars = AssocList C.Name LocalVar

-- | For each bound variable, we want to know whether it was bound by a
--   λ, Π, module telescope, pattern, or @let@.
data BindingSource
  = LambdaBound  -- ^ @λ@ (currently also used for @Π@ and module parameters)
  | PatternBound -- ^ @f ... =@
  | LetBound     -- ^ @let ... in@
  deriving (Data, Show, Eq)

-- | A local variable can be shadowed by an import.
--   In case of reference to a shadowed variable, we want to report
--   a scope error.
data LocalVar = LocalVar
  { localVar           :: A.Name
    -- ^ Unique ID of local variable.
  , localBindingSource :: BindingSource
    -- ^ Kind of binder used to introduce the variable (@λ@, @let@, ...).
  , localShadowedBy    :: [AbstractName]
     -- ^ If this list is not empty, the local variable is
     --   shadowed by one or more imports.
  }
  deriving (Data, Show)

instance Eq LocalVar where
  (==) = (==) `on` localVar

instance Ord LocalVar where
  compare = compare `on` localVar

-- | We show shadowed variables as prefixed by a ".", as not in scope.
instance Pretty LocalVar where
  pretty (LocalVar x _ []) = pretty x
  pretty (LocalVar x _ xs) = "." <> pretty x

-- | Shadow a local name by a non-empty list of imports.
shadowLocal :: [AbstractName] -> LocalVar -> LocalVar
shadowLocal [] _ = __IMPOSSIBLE__
shadowLocal ys (LocalVar x b zs) = LocalVar x b (ys ++ zs)

-- | Treat patternBound variable as a module parameter
patternToModuleBound :: LocalVar -> LocalVar
patternToModuleBound x
 | localBindingSource x == PatternBound =
   x { localBindingSource = LambdaBound }
 | otherwise                     = x

-- | Project name of unshadowed local variable.
notShadowedLocal :: LocalVar -> Maybe A.Name
notShadowedLocal (LocalVar x _ []) = Just x
notShadowedLocal _ = Nothing

-- | Get all locals that are not shadowed __by imports__.
notShadowedLocals :: LocalVars -> AssocList C.Name A.Name
notShadowedLocals = mapMaybe $ \ (c,x) -> (c,) <$> notShadowedLocal x

-- | Lenses for ScopeInfo components
scopeCurrent :: Lens' A.ModuleName ScopeInfo
scopeCurrent f s =
  f (_scopeCurrent s) <&>
  \x -> s { _scopeCurrent = x }

scopeModules :: Lens' (Map A.ModuleName Scope) ScopeInfo
scopeModules f s =
  f (_scopeModules s) <&>
  \x -> s { _scopeModules = x }

scopeVarsToBind :: Lens' LocalVars ScopeInfo
scopeVarsToBind f s =
  f (_scopeVarsToBind s) <&>
  \x -> s { _scopeVarsToBind = x }

scopeLocals :: Lens' LocalVars ScopeInfo
scopeLocals f s =
  f (_scopeLocals s) <&>
  \x -> s { _scopeLocals = x }

scopePrecedence :: Lens' PrecedenceStack ScopeInfo
scopePrecedence f s =
  f (_scopePrecedence s) <&>
  \x -> s { _scopePrecedence = x }

scopeInverseName :: Lens' NameMap ScopeInfo
scopeInverseName f s =
  f (_scopeInverseName s) <&>
  \x -> s { _scopeInverseName = x }

scopeInverseModule :: Lens' ModuleMap ScopeInfo
scopeInverseModule f s =
  f (_scopeInverseModule s) <&>
  \x -> s { _scopeInverseModule = x }

scopeInScope :: Lens' InScopeSet ScopeInfo
scopeInScope f s =
  f (_scopeInScope s) <&>
  \x -> s { _scopeInScope = x }

scopeFixities :: Lens' C.Fixities ScopeInfo
scopeFixities f s =
  f (_scopeFixities s) <&>
  \x -> s { _scopeFixities = x }

scopePolarities :: Lens' C.Polarities ScopeInfo
scopePolarities f s =
  f (_scopePolarities s) <&>
  \x -> s { _scopePolarities = x }

scopeFixitiesAndPolarities :: Lens' (C.Fixities, C.Polarities) ScopeInfo
scopeFixitiesAndPolarities f s =
  f' (_scopeFixities s) (_scopePolarities s) <&>
  \ (fixs, pols) -> s { _scopeFixities = fixs, _scopePolarities = pols }
  where
  -- Andreas, 2019-08-18: strict matching avoids space leak, see #1829.
  f' !fixs !pols = f (fixs, pols)
  -- Andrea comments on https://github.com/agda/agda/issues/1829#issuecomment-522312084
  -- on a naive version without the bang patterns:
  --
  -- useScope (because of useR) forces the result of projecting the
  -- lens, this usually prevents retaining the whole structure when we
  -- only need a field.  However your combined lens adds an extra layer
  -- of laziness with the pairs, so the actual projections remain
  -- unforced.
  --
  -- I guess scopeFixitiesAndPolarities could add some strictness when building the pair?

-- | Lens for 'scopeVarsToBind'.
updateVarsToBind :: (LocalVars -> LocalVars) -> ScopeInfo -> ScopeInfo
updateVarsToBind = over scopeVarsToBind

setVarsToBind :: LocalVars -> ScopeInfo -> ScopeInfo
setVarsToBind = set scopeVarsToBind

-- | Lens for 'scopeLocals'.
updateScopeLocals :: (LocalVars -> LocalVars) -> ScopeInfo -> ScopeInfo
updateScopeLocals = over scopeLocals

setScopeLocals :: LocalVars -> ScopeInfo -> ScopeInfo
setScopeLocals = set scopeLocals

------------------------------------------------------------------------
-- * Name spaces
--
-- Map concrete names to lists of abstract names.
------------------------------------------------------------------------

-- | A @NameSpace@ contains the mappings from concrete names that the user can
--   write to the abstract fully qualified names that the type checker wants to
--   read.
data NameSpace = NameSpace
      { nsNames   :: NamesInScope
        -- ^ Maps concrete names to a list of abstract names.
      , nsModules :: ModulesInScope
        -- ^ Maps concrete module names to a list of abstract module names.
      , nsInScope :: InScopeSet
        -- ^ All abstract names targeted by a concrete name in scope.
        --   Computed by 'recomputeInScopeSets'.
      }
  deriving (Data, Eq, Show)

type ThingsInScope a = Map C.Name [a]
type NamesInScope    = ThingsInScope AbstractName
type ModulesInScope  = ThingsInScope AbstractModule
type InScopeSet      = Set A.QName

-- | Set of types consisting of exactly 'AbstractName' and 'AbstractModule'.
--
--   A GADT just for some dependent-types trickery.
data InScopeTag a where
  NameTag   :: InScopeTag AbstractName
  ModuleTag :: InScopeTag AbstractModule

-- | Type class for some dependent-types trickery.
class Eq a => InScope a where
  inScopeTag :: InScopeTag a

instance InScope AbstractName where
  inScopeTag = NameTag

instance InScope AbstractModule where
  inScopeTag = ModuleTag

-- | @inNameSpace@ selects either the name map or the module name map from
--   a 'NameSpace'.  What is selected is determined by result type
--   (using the dependent-type trickery).
inNameSpace :: forall a. InScope a => NameSpace -> ThingsInScope a
inNameSpace = case inScopeTag :: InScopeTag a of
  NameTag   -> nsNames
  ModuleTag -> nsModules

-- | Non-dependent tag for name or module.
data NameOrModule = NameNotModule | ModuleNotName
  deriving (Data, Eq, Ord, Show, Enum, Bounded)

------------------------------------------------------------------------
-- * Decorated names
--
-- - What kind of name? (defined, constructor...)
-- - Where does the name come from? (to explain to user)
------------------------------------------------------------------------

-- | For the sake of parsing left-hand sides, we distinguish
--   constructor and record field names from defined names.

-- Note: order does matter in this enumeration, see 'isDefName'.
data KindOfName
  = ConName                  -- ^ Constructor name.
  | FldName                  -- ^ Record field name.
  | PatternSynName           -- ^ Name of a pattern synonym.
  | GeneralizeName           -- ^ Name to be generalized
  | DisallowedGeneralizeName -- ^ Generalizable variable from a let open
  | MacroName                -- ^ Name of a macro
  | QuotableName             -- ^ A name that can only be quoted.
  -- Previous category @DefName@:
  -- (Refined in a flat manner as Enum and Bounded are not hereditary.)
  | DataName                 -- ^ Name of a @data@.
  | RecName                  -- ^ Name of a @record@.
  | FunName                  -- ^ Name of a defined function.
  | AxiomName                -- ^ Name of a @postulate@.
  | PrimName                 -- ^ Name of a @primitive@.
  | OtherDefName             -- ^ A @DefName@, but either other kind or don't know which kind.
  -- End @DefName@.  Keep these together in sequence, for sake of @isDefName@!
  deriving (Eq, Ord, Show, Data, Enum, Bounded)

isDefName :: KindOfName -> Bool
isDefName = (>= DataName)

-- | A set of 'KindOfName', for the sake of 'elemKindsOfNames'.
data KindsOfNames
  = AllKindsOfNames
  | SomeKindsOfNames   (Set KindOfName)  -- ^ Only these kinds.
  | ExceptKindsOfNames (Set KindOfName)  -- ^ All but these Kinds.

elemKindsOfNames :: KindOfName -> KindsOfNames -> Bool
elemKindsOfNames k = \case
  AllKindsOfNames       -> True
  SomeKindsOfNames   ks -> k `Set.member` ks
  ExceptKindsOfNames ks -> k `Set.notMember` ks

allKindsOfNames :: KindsOfNames
allKindsOfNames = AllKindsOfNames

someKindsOfNames :: [KindOfName] -> KindsOfNames
someKindsOfNames = SomeKindsOfNames . Set.fromList

exceptKindsOfNames :: [KindOfName] -> KindsOfNames
exceptKindsOfNames = ExceptKindsOfNames . Set.fromList

-- | Where does a name come from?
--
--   This information is solely for reporting to the user,
--   see 'Agda.Interaction.InteractionTop.whyInScope'.
data WhyInScope
  = Defined
    -- ^ Defined in this module.
  | Opened C.QName WhyInScope
    -- ^ Imported from another module.
  | Applied C.QName WhyInScope
    -- ^ Imported by a module application.
  deriving (Data, Show)

-- | A decoration of 'Agda.Syntax.Abstract.Name.QName'.
data AbstractName = AbsName
  { anameName    :: A.QName
    -- ^ The resolved qualified name.
  , anameKind    :: KindOfName
    -- ^ The kind (definition, constructor, record field etc.).
  , anameLineage :: WhyInScope
    -- ^ Explanation where this name came from.
  , anameMetadata :: NameMetadata
    -- ^ Additional information needed during scope checking. Currently used
    --   for generalized data/record params.
  }
  deriving (Data, Show)

data NameMetadata = NoMetadata
                  | GeneralizedVarsMetadata (Map A.QName A.Name)
  deriving (Data, Show)

-- | A decoration of abstract syntax module names.
data AbstractModule = AbsModule
  { amodName    :: A.ModuleName
    -- ^ The resolved module name.
  , amodLineage :: WhyInScope
    -- ^ Explanation where this name came from.
  }
  deriving (Data, Show)

instance Eq AbstractName where
  (==) = (==) `on` anameName

instance Ord AbstractName where
  compare = compare `on` anameName

instance LensFixity AbstractName where
  lensFixity = lensAnameName . lensFixity

-- | Van Laarhoven lens on 'anameName'.
lensAnameName :: Functor m => (A.QName -> m A.QName) -> AbstractName -> m AbstractName
lensAnameName f am = f (anameName am) <&> \ m -> am { anameName = m }

instance Eq AbstractModule where
  (==) = (==) `on` amodName

instance Ord AbstractModule where
  compare = compare `on` amodName

-- | Van Laarhoven lens on 'amodName'.
lensAmodName :: Functor m => (A.ModuleName -> m A.ModuleName) -> AbstractModule -> m AbstractModule
lensAmodName f am = f (amodName am) <&> \ m -> am { amodName = m }


data ResolvedName
  = -- | Local variable bound by λ, Π, module telescope, pattern, @let@.
    VarName
    { resolvedVar           :: A.Name
    , resolvedBindingSource :: BindingSource    -- ^ What kind of binder?
    }

  | -- | Function, data/record type, postulate.
    DefinedName Access AbstractName -- ^ 'anameKind' can be 'DefName', 'MacroName', 'QuotableName'.

  | -- | Record field name.  Needs to be distinguished to parse copatterns.
    FieldName (NonemptyList AbstractName)       -- ^ @('FldName' ==) . 'anameKind'@ for all names.

  | -- | Data or record constructor name.
    ConstructorName (NonemptyList AbstractName) -- ^ @('ConName' ==) . 'anameKind'@ for all names.

  | -- | Name of pattern synonym.
    PatternSynResName (NonemptyList AbstractName) -- ^ @('PatternSynName' ==) . 'anameKind'@ for all names.

  | -- | Unbound name.
    UnknownName
  deriving (Data, Show, Eq)

instance Pretty ResolvedName where
  pretty = \case
    VarName x _         -> "variable"    <+> pretty x
    DefinedName a x     -> pretty a           <+> pretty x
    FieldName xs        -> "field"       <+> pretty xs
    ConstructorName xs  -> "constructor" <+> pretty xs
    PatternSynResName x -> "pattern"     <+> pretty x
    UnknownName         -> "<unknown name>"

-- * Operations on name and module maps.

mergeNames :: Eq a => ThingsInScope a -> ThingsInScope a -> ThingsInScope a
mergeNames = Map.unionWith List.union

mergeNamesMany :: Eq a => [ThingsInScope a] -> ThingsInScope a
mergeNamesMany = Map.unionsWith List.union

------------------------------------------------------------------------
-- * Operations on name spaces
------------------------------------------------------------------------

-- | The empty name space.
emptyNameSpace :: NameSpace
emptyNameSpace = NameSpace Map.empty Map.empty Set.empty


-- | Map functions over the names and modules in a name space.
mapNameSpace :: (NamesInScope   -> NamesInScope  ) ->
                (ModulesInScope -> ModulesInScope) ->
                (InScopeSet     -> InScopeSet    ) ->
                NameSpace -> NameSpace
mapNameSpace fd fm fs ns =
  ns { nsNames   = fd $ nsNames   ns
     , nsModules = fm $ nsModules ns
     , nsInScope = fs $ nsInScope ns
     }

-- | Zip together two name spaces.
zipNameSpace :: (NamesInScope   -> NamesInScope   -> NamesInScope  ) ->
                (ModulesInScope -> ModulesInScope -> ModulesInScope) ->
                (InScopeSet     -> InScopeSet     -> InScopeSet    ) ->
                NameSpace -> NameSpace -> NameSpace
zipNameSpace fd fm fs ns1 ns2 =
  ns1 { nsNames   = nsNames   ns1 `fd` nsNames   ns2
      , nsModules = nsModules ns1 `fm` nsModules ns2
      , nsInScope = nsInScope ns1 `fs` nsInScope ns2
      }

-- | Map monadic function over a namespace.
mapNameSpaceM :: Applicative m =>
  (NamesInScope   -> m NamesInScope  ) ->
  (ModulesInScope -> m ModulesInScope) ->
  (InScopeSet     -> m InScopeSet    ) ->
  NameSpace -> m NameSpace
mapNameSpaceM fd fm fs ns = update ns <$> fd (nsNames ns) <*> fm (nsModules ns) <*> fs (nsInScope ns)
  where
    update ns ds ms is = ns { nsNames = ds, nsModules = ms, nsInScope = is }

------------------------------------------------------------------------
-- * General operations on scopes
------------------------------------------------------------------------

-- | The empty scope.
emptyScope :: Scope
emptyScope = Scope
  { scopeName           = noModuleName
  , scopeParents        = []
  , scopeNameSpaces     = [ (nsid, emptyNameSpace) | nsid <- allNameSpaces ]
      -- Note (Andreas, 2019-08-19):  Cannot have [] here because
      -- zipScope assumes all NameSpaces to be present and in the same order.
  , scopeImports        = Map.empty
  , scopeDatatypeModule = Nothing
  }

-- | The empty scope info.
emptyScopeInfo :: ScopeInfo
emptyScopeInfo = ScopeInfo
  { _scopeCurrent       = noModuleName
  , _scopeModules       = Map.singleton noModuleName emptyScope
  , _scopeVarsToBind    = []
  , _scopeLocals        = []
  , _scopePrecedence    = []
  , _scopeInverseName   = Map.empty
  , _scopeInverseModule = Map.empty
  , _scopeInScope       = Set.empty
  , _scopeFixities      = Map.empty
  , _scopePolarities    = Map.empty
  }

-- | Map functions over the names and modules in a scope.
mapScope :: (NameSpaceId -> NamesInScope   -> NamesInScope  ) ->
            (NameSpaceId -> ModulesInScope -> ModulesInScope) ->
            (NameSpaceId -> InScopeSet    -> InScopeSet     ) ->
            Scope -> Scope
mapScope fd fm fs = updateScopeNameSpaces $ AssocList.mapWithKey mapNS
  where
    mapNS acc = mapNameSpace (fd acc) (fm acc) (fs acc)

-- | Same as 'mapScope' but applies the same function to all name spaces.
mapScope_ :: (NamesInScope   -> NamesInScope  ) ->
             (ModulesInScope -> ModulesInScope) ->
             (InScopeSet     -> InScopeSet    ) ->
             Scope -> Scope
mapScope_ fd fm fs = mapScope (const fd) (const fm) (const fs)

-- | Same as 'mapScope' but applies the function only on the given name space.
mapScopeNS :: NameSpaceId
           -> (NamesInScope   -> NamesInScope  )
           -> (ModulesInScope -> ModulesInScope)
           -> (InScopeSet    -> InScopeSet     )
           -> Scope -> Scope
mapScopeNS nsid fd fm fs = modifyNameSpace nsid $ mapNameSpace fd fm fs

-- | Map monadic functions over the names and modules in a scope.
mapScopeM :: Applicative m =>
  (NameSpaceId -> NamesInScope   -> m NamesInScope  ) ->
  (NameSpaceId -> ModulesInScope -> m ModulesInScope) ->
  (NameSpaceId -> InScopeSet     -> m InScopeSet    ) ->
  Scope -> m Scope
mapScopeM fd fm fs = updateScopeNameSpacesM $ AssocList.mapWithKeyM mapNS
  where
    mapNS acc = mapNameSpaceM (fd acc) (fm acc) (fs acc)

-- | Same as 'mapScopeM' but applies the same function to both the public and
--   private name spaces.
mapScopeM_ :: Applicative m =>
  (NamesInScope   -> m NamesInScope  ) ->
  (ModulesInScope -> m ModulesInScope) ->
  (InScopeSet     -> m InScopeSet    ) ->
  Scope -> m Scope
mapScopeM_ fd fm fs = mapScopeM (const fd) (const fm) (const fs)

-- | Zip together two scopes. The resulting scope has the same name as the
--   first scope.
zipScope :: (NameSpaceId -> NamesInScope   -> NamesInScope   -> NamesInScope  ) ->
            (NameSpaceId -> ModulesInScope -> ModulesInScope -> ModulesInScope) ->
            (NameSpaceId -> InScopeSet     -> InScopeSet     -> InScopeSet    ) ->
            Scope -> Scope -> Scope
zipScope fd fm fs s1 s2 =
  s1 { scopeNameSpaces =
         [ (nsid, zipNS nsid ns1 ns2)
         | ((nsid, ns1), (nsid', ns2)) <-
             fromMaybe __IMPOSSIBLE__ $
               zipWith' (,) (scopeNameSpaces s1) (scopeNameSpaces s2)
         , assert (nsid == nsid')
         ]
     , scopeImports  = (Map.union `on` scopeImports)  s1 s2
     }
  where
    assert True  = True
    assert False = __IMPOSSIBLE__
    zipNS acc = zipNameSpace (fd acc) (fm acc) (fs acc)

-- | Same as 'zipScope' but applies the same function to both the public and
--   private name spaces.
zipScope_ :: (NamesInScope   -> NamesInScope   -> NamesInScope  ) ->
             (ModulesInScope -> ModulesInScope -> ModulesInScope) ->
             (InScopeSet     -> InScopeSet     -> InScopeSet    ) ->
             Scope -> Scope -> Scope
zipScope_ fd fm fs = zipScope (const fd) (const fm) (const fs)

-- | Recompute the inScope sets of a scope.
recomputeInScopeSets :: Scope -> Scope
recomputeInScopeSets = updateScopeNameSpaces (map $ second recomputeInScope)
  where
    recomputeInScope ns = ns { nsInScope = allANames $ nsNames ns }
    allANames :: NamesInScope -> InScopeSet
    allANames = Set.fromList . map anameName . concat . Map.elems

-- | Filter a scope keeping only concrete names matching the predicates.
--   The first predicate is applied to the names and the second to the modules.
filterScope :: (C.Name -> Bool) -> (C.Name -> Bool) -> Scope -> Scope
filterScope pd pm = recomputeInScopeSets .  mapScope_ (Map.filterKeys pd) (Map.filterKeys pm) id
  -- We don't have enough information in the in scope set to do an
  -- incremental update here, so just recompute it from the name map.

-- | Return all names in a scope.
allNamesInScope :: InScope a => Scope -> ThingsInScope a
allNamesInScope = mergeNamesMany . map (inNameSpace . snd) . scopeNameSpaces

allNamesInScope' :: InScope a => Scope -> ThingsInScope (a, Access)
allNamesInScope' s =
  mergeNamesMany [ map (, nameSpaceAccess nsId) <$> inNameSpace ns
                 | (nsId, ns) <- scopeNameSpaces s ]

-- | Returns the scope's non-private names.
exportedNamesInScope :: InScope a => Scope -> ThingsInScope a
exportedNamesInScope = namesInScope [PublicNS, ImportedNS, OnlyQualifiedNS]

namesInScope :: InScope a => [NameSpaceId] -> Scope -> ThingsInScope a
namesInScope ids s =
  mergeNamesMany [ inNameSpace (scopeNameSpace nsid s) | nsid <- ids ]

allThingsInScope :: Scope -> NameSpace
allThingsInScope s =
  NameSpace { nsNames   = allNamesInScope s
            , nsModules = allNamesInScope s
            , nsInScope = Set.unions $ map (nsInScope . snd) $ scopeNameSpaces s
            }

thingsInScope :: [NameSpaceId] -> Scope -> NameSpace
thingsInScope fs s =
  NameSpace { nsNames   = namesInScope fs s
            , nsModules = namesInScope fs s
            , nsInScope = Set.unions [ nsInScope $ scopeNameSpace nsid s | nsid <- fs ]
            }

-- | Merge two scopes. The result has the name of the first scope.
mergeScope :: Scope -> Scope -> Scope
mergeScope = zipScope_ mergeNames mergeNames Set.union

-- | Merge a non-empty list of scopes. The result has the name of the first
--   scope in the list.
mergeScopes :: [Scope] -> Scope
mergeScopes [] = __IMPOSSIBLE__
mergeScopes ss = foldr1 mergeScope ss

-- * Specific operations on scopes

-- | Move all names in a scope to the given name space (except never move from
--   Imported to Public).
setScopeAccess :: NameSpaceId -> Scope -> Scope
setScopeAccess a s = (`updateScopeNameSpaces` s) $ AssocList.mapWithKey $ const . ns
  where
    zero  = emptyNameSpace
    one   = allThingsInScope s
    imp   = thingsInScope [ImportedNS] s
    noimp = thingsInScope [PublicNS, PrivateNS, OnlyQualifiedNS] s

    ns b = case (a, b) of
      (PublicNS, PublicNS)   -> noimp
      (PublicNS, ImportedNS) -> imp
      _ | a == b             -> one
        | otherwise          -> zero

-- | Update a particular name space.
setNameSpace :: NameSpaceId -> NameSpace -> Scope -> Scope
setNameSpace nsid ns = modifyNameSpace nsid $ const ns

-- | Modify a particular name space.
modifyNameSpace :: NameSpaceId -> (NameSpace -> NameSpace) -> Scope -> Scope
modifyNameSpace nsid f = updateScopeNameSpaces $ AssocList.updateAt nsid f

-- | Add a name to a scope.
addNameToScope :: NameSpaceId -> C.Name -> AbstractName -> Scope -> Scope
addNameToScope nsid x y =
  mapScopeNS nsid
    (Map.insertWith (flip List.union) x [y])  -- bind name x ↦ y
    id                                        -- no change to modules
    (Set.insert $ anameName y)                -- y is in scope now

-- | Remove a name from a scope. Caution: does not update the nsInScope set.
--   This is only used by rebindName and in that case we add the name right
--   back (but with a different kind).
removeNameFromScope :: NameSpaceId -> C.Name -> Scope -> Scope
removeNameFromScope nsid x = mapScopeNS nsid (Map.delete x) id id

-- | Add a module to a scope.
addModuleToScope :: NameSpaceId -> C.Name -> AbstractModule -> Scope -> Scope
addModuleToScope nsid x m = mapScopeNS nsid id addM id
  where addM = Map.insertWith (flip List.union) x [m]

-- | When we get here we cannot have both @using@ and @hiding@.
data UsingOrHiding
  = UsingOnly  [C.ImportedName]
  | HidingOnly [C.ImportedName]

usingOrHiding :: C.ImportDirective -> UsingOrHiding
usingOrHiding i =
  case (using i, hiding i) of
    (UseEverything, ys) -> HidingOnly ys
    (Using xs     , []) -> UsingOnly  xs
    _                   -> __IMPOSSIBLE__

-- | Apply an 'ImportDirective' to a scope:
--
--   1. rename keys (C.Name) according to @renaming@;
--
--   2. for untouched keys, either of
--
--      a) remove keys according to @hiding@, or
--      b) filter keys according to @using@.
--
--   Both steps could be done in one pass, by first preparing key-filtering
--   functions @C.Name -> Maybe C.Name@ for defined names and module names.
--   However, the penalty of doing it in two passes should not be too high.
--   (Doubling the run time.)
applyImportDirective :: C.ImportDirective -> Scope -> Scope
applyImportDirective dir = fst . applyImportDirective_ dir

-- | Version of 'applyImportDirective' that also returns sets of name
--   and module name clashes introduced by @renaming@ to identifiers
--   that are already imported by @using@ or lack of @hiding@.
applyImportDirective_
  :: C.ImportDirective
  -> Scope
  -> (Scope, (Set C.Name, Set C.Name)) -- ^ Merged scope, clashing names, clashing module names.
applyImportDirective_ dir@(ImportDirective{ impRenaming }) s
  | null dir  = (s, (empty, empty))
      -- Since each run of applyImportDirective rebuilds the scope
      -- with cost O(n log n) time, it makes sense to test for the identity.
  | otherwise = (mergeScope sUse sRen, (nameClashes, moduleClashes))
  where
    -- | Names kept via using/hiding.
    sUse :: Scope
    sUse = useOrHide (usingOrHiding dir) s

    -- | Things kept (under a different name) via renaming.
    sRen :: Scope
    sRen = rename impRenaming s

    -- | Which names are considered to be defined by a module?
    --   The ones actually defined there publicly ('publicNS')
    --   and the ones imported publicly ('ImportedNS')?

    --   TODO: Also 'OnlyQualifiedNS'?
    --   exportedNamesInScope sUse ?
    exportedNSs = [PublicNS, ImportedNS]

    -- | Name clashes introduced by the @renaming@ clause.
    nameClashes :: Set C.Name
    nameClashes = Map.keysSet rNames `Set.intersection` Map.keysSet uNames
      -- NB: `intersection` returns a subset of the first argument.
      -- To get the correct error location, i.e., in the @renaming@ clause
      -- rather than at the definition location, we neet to return
      -- names from the @renaming@ clause.  (Issue #4154.)
      where
      uNames, rNames :: NamesInScope
      uNames = namesInScope exportedNSs sUse
      rNames = namesInScope exportedNSs sRen

    -- | Module name clashes introduced by the @renaming@ clause.

    -- Note: need to cut and paste because of 'InScope' dependent types trickery.
    moduleClashes :: Set C.Name
    moduleClashes = Map.keysSet uModules `Set.intersection` Map.keysSet rModules
      where
      uModules, rModules :: ModulesInScope
      uModules = namesInScope exportedNSs sUse
      rModules = namesInScope exportedNSs sRen


    -- Restrict scope by directive.
    useOrHide :: UsingOrHiding -> Scope -> Scope
    useOrHide (UsingOnly  xs) = filterNames Set.member xs
       -- Filter scope, keeping only xs.
    useOrHide (HidingOnly xs) = filterNames Set.notMember $ map renFrom impRenaming ++ xs
       -- Filter out xs and the to be renamed names from scope.

    -- Filter scope by (`rel` xs).
    -- O(n * log (length xs)).
    filterNames :: (C.Name -> Set C.Name -> Bool) -> [C.ImportedName] ->
                   Scope -> Scope
    filterNames rel xs = filterScope (`rel` Set.fromList ds) (`rel` Set.fromList ms)
      where
        (ds, ms) = partitionEithers $ for xs $ \case
          ImportedName   x -> Left x
          ImportedModule m -> Right m

    -- Apply a renaming to a scope.
    -- O(n * (log n + log (length rho))).
    rename :: [C.Renaming] -> Scope -> Scope
    rename rho = mapScope_ (updateFxs .
                            Map.mapMaybeKeys (AssocList.apply drho))
                           (Map.mapMaybeKeys (AssocList.apply mrho))
                           id
      where
        (drho, mrho) = partitionEithers $ for rho $ \case
          Renaming (ImportedName   x) (ImportedName   y) _fx _ -> Left  (x, y)
          Renaming (ImportedModule x) (ImportedModule y) _fx _ -> Right (x, y)
          _ -> __IMPOSSIBLE__

        fixities :: AssocList C.Name Fixity
        fixities = (`mapMaybe` rho) $ \case
          Renaming _ (ImportedName y) (Just fx)  _ -> Just (y, fx)
          _ -> Nothing

        -- Update fixities of abstract names targeted by renamed imported identifies.
        updateFxs :: NamesInScope -> NamesInScope
        updateFxs m = foldl upd m fixities
          where
          -- Update fixity of all abstract names targeted by concrete name y.
          upd m (y, fx) = Map.adjust (map $ set lensFixity fx) y m


-- | Rename the abstract names in a scope.
renameCanonicalNames :: Map A.QName A.QName -> Map A.ModuleName A.ModuleName ->
                        Scope -> Scope
renameCanonicalNames renD renM = mapScope_ renameD renameM (Set.map newName)
  where
    newName x = Map.findWithDefault x x renD
    newMod  x = Map.findWithDefault x x renM

    renameD = Map.map $ map $ over lensAnameName newName
    renameM = Map.map $ map $ over lensAmodName  newMod

-- | Remove private name space of a scope.
--
--   Should be a right identity for 'exportedNamesInScope'.
--   @exportedNamesInScope . restrictPrivate == exportedNamesInScope@.
restrictPrivate :: Scope -> Scope
restrictPrivate s = setNameSpace PrivateNS emptyNameSpace
                  $ s { scopeImports = Map.empty }

-- | Remove private things from the given module from a scope.
restrictLocalPrivate :: ModuleName -> Scope -> Scope
restrictLocalPrivate m =
  mapScopeNS PrivateNS
    (Map.mapMaybe rName)
    (Map.mapMaybe rMod)
    (Set.filter (not . (`isInModule` m)))
  where
    rName as = filterMaybe (not . null) $ filter (not . (`isInModule`        m) . anameName) as
    rMod  as = filterMaybe (not . null) $ filter (not . (`isLtChildModuleOf` m) . amodName)  as

-- | Remove names that can only be used qualified (when opening a scope)
removeOnlyQualified :: Scope -> Scope
removeOnlyQualified s = setNameSpace OnlyQualifiedNS emptyNameSpace s

-- | Disallow using generalized variables from the scope
disallowGeneralizedVars :: Scope -> Scope
disallowGeneralizedVars = mapScope_ ((fmap . map) disallow) id id
  where
    disallow a = a { anameKind = disallowGen (anameKind a) }
    disallowGen GeneralizeName = DisallowedGeneralizeName
    disallowGen k              = k

-- | Add an explanation to why things are in scope.
inScopeBecause :: (WhyInScope -> WhyInScope) -> Scope -> Scope
inScopeBecause f = mapScope_ mapName mapMod id
  where
    mapName = fmap . map $ \a -> a { anameLineage = f $ anameLineage a }
    mapMod  = fmap . map $ \a -> a { amodLineage  = f $ amodLineage a  }

-- | Get the public parts of the public modules of a scope
publicModules :: ScopeInfo -> Map A.ModuleName Scope
publicModules scope = Map.filterWithKey (\ m _ -> reachable m) allMods
  where
    -- Get all modules in the ScopeInfo.
    allMods   = Map.map restrictPrivate $ scope ^. scopeModules
    root      = scope ^. scopeCurrent

    modules s = map amodName $ concat $ Map.elems $ allNamesInScope s

    chase m = m : concatMap chase ms
      where ms = maybe __IMPOSSIBLE__ modules $ Map.lookup m allMods

    reachable = (`elem` chase root)

publicNames :: ScopeInfo -> Set AbstractName
publicNames scope =
  Set.fromList $ concat $ Map.elems $
  exportedNamesInScope $ mergeScopes $ Map.elems $ publicModules scope

everythingInScope :: ScopeInfo -> NameSpace
everythingInScope scope = allThingsInScope $ mergeScopes $
    (s0 :) $ map look $ scopeParents s0
  where
    look m = fromMaybe __IMPOSSIBLE__ $ Map.lookup m $ scope ^. scopeModules
    s0     = look $ scope ^. scopeCurrent

everythingInScopeQualified :: ScopeInfo -> NameSpace
everythingInScopeQualified scope =
  allThingsInScope $ mergeScopes $
    chase Set.empty scopes
  where
    s0      = look $ scope ^. scopeCurrent
    scopes  = s0 : map look (scopeParents s0)
    look m  = fromMaybe __IMPOSSIBLE__ $ Map.lookup m $ scope ^. scopeModules
    lookP   = restrictPrivate . look

    -- We start with the current module and all its parents and look through
    -- all their imports and submodules.
    chase seen [] = []
    chase seen (s : ss)
      | Set.member name seen = chase seen ss
      | otherwise = s : chase (Set.insert name seen) (imports ++ submods ++ ss)
      where
        name    = scopeName s
        imports = map lookP $ Map.elems $ scopeImports s
        submods = map (lookP . amodName) $ concat $ Map.elems $ allNamesInScope s

-- | Compute a flattened scope. Only include unqualified names or names
-- qualified by modules in the first argument.
flattenScope :: [[C.Name]] -> ScopeInfo -> Map C.QName [AbstractName]
flattenScope ms scope =
  Map.unionWith (++)
    (build ms allNamesInScope root)
    imported
  where
    current = moduleScope $ scope ^. scopeCurrent
    root    = mergeScopes $ current : map moduleScope (scopeParents current)

    imported = Map.unionsWith (++)
               [ qual c (build ms' exportedNamesInScope $ moduleScope a)
               | (c, a) <- Map.toList $ scopeImports root
               , let -- get the suffixes of c in ms
                     ms' = mapMaybe (List.stripPrefix $ C.qnameParts c) ms
               , not $ null ms' ]
    qual c = Map.mapKeys (q c)
      where
        q (C.QName x)  = C.Qual x
        q (C.Qual m x) = C.Qual m . q x

    build :: [[C.Name]] -> (forall a. InScope a => Scope -> ThingsInScope a) -> Scope -> Map C.QName [AbstractName]
    build ms getNames s = Map.unionsWith (++) $
        (Map.mapKeysMonotonic C.QName $ getNames s) :
          [ Map.mapKeysMonotonic (\ y -> C.Qual x y) $
              build ms' exportedNamesInScope $ moduleScope m
          | (x, mods) <- Map.toList (getNames s)
          , let ms' = [ tl | hd:tl <- ms, hd == x ]
          , not $ null ms'
          , AbsModule m _ <- mods ]

    moduleScope :: A.ModuleName -> Scope
    moduleScope m = fromMaybe __IMPOSSIBLE__ $ Map.lookup m $ scope ^. scopeModules

-- | Get all concrete names in scope. Includes bound variables.
concreteNamesInScope :: ScopeInfo -> Set C.QName
concreteNamesInScope scope =
  Set.unions [ build allNamesInScope root, imported, locals ]
  where
    current = moduleScope $ scope ^. scopeCurrent
    root    = mergeScopes $ current : map moduleScope (scopeParents current)

    locals  = Set.fromList [ C.QName x | (x, _) <- scope ^. scopeLocals ]

    imported = Set.unions
               [ qual c (build exportedNamesInScope $ moduleScope a)
               | (c, a) <- Map.toList $ scopeImports root ]
    qual c = Set.map (q c)
      where
        q (C.QName x)  = C.Qual x
        q (C.Qual m x) = C.Qual m . q x

    build :: (forall a. InScope a => Scope -> ThingsInScope a) -> Scope -> Set C.QName
    build getNames s = Set.unions $
        (Set.fromList $ map C.QName $ Map.keys (getNames s :: ThingsInScope AbstractName)) :
          [ Set.mapMonotonic (\ y -> C.Qual x y) $
              build exportedNamesInScope $ moduleScope m
          | (x, mods) <- Map.toList (getNames s)
          , prettyShow x /= "_"
          , AbsModule m _ <- mods ]

    moduleScope :: A.ModuleName -> Scope
    moduleScope m = fromMaybe __IMPOSSIBLE__ $ Map.lookup m $ scope ^. scopeModules

-- | Look up a name in the scope
scopeLookup :: InScope a => C.QName -> ScopeInfo -> [a]
scopeLookup q scope = map fst $ scopeLookup' q scope

scopeLookup' :: forall a. InScope a => C.QName -> ScopeInfo -> [(a, Access)]
scopeLookup' q scope =
  List.nubBy ((==) `on` fst) $
    findName q root ++ maybeToList topImports ++ imports
  where

    -- 1. Finding a name in the current scope and its parents.

    moduleScope :: A.ModuleName -> Scope
    moduleScope m = fromMaybe __IMPOSSIBLE__ $ Map.lookup m $ scope ^. scopeModules

    current :: Scope
    current = moduleScope $ scope ^. scopeCurrent

    root    :: Scope
    root    = mergeScopes $ current : map moduleScope (scopeParents current)

    -- | Find a concrete, possibly qualified name in scope @s@.
    findName :: forall a. InScope a => C.QName -> Scope -> [(a, Access)]
    findName q0 s = case q0 of
      C.QName x  -> lookupName x s
      C.Qual x q -> do
        let -- | Get the modules named @x@ in scope @s@.
            mods :: [A.ModuleName]
            mods = amodName . fst <$> lookupName x s
            -- | Get the definitions named @x@ in scope @s@ and interpret them as modules.
            -- Andreas, 2013-05-01: Issue 836 debates this feature:
            -- Qualified constructors are qualified by their datatype rather than a module
            defs :: [A.ModuleName]
            defs = mnameFromList . qnameToList . anameName . fst <$> lookupName x s
        -- Andreas, 2013-05-01:  Issue 836 complains about the feature
        -- that constructors can also be qualified by their datatype
        -- and projections by their record type.  This feature is off
        -- if we just consider the modules:
        m <- mods
        -- The feature is on if we consider also the data and record types:
        -- trace ("mods ++ defs = " ++ show (mods ++ defs)) $ do
        -- m <- nub $ mods ++ defs -- record types will appear both as a mod and a def
        -- Get the scope of module m, if any, and remove its private definitions.
        let ss  = Map.lookup m $ scope ^. scopeModules
            ss' = restrictPrivate <$> ss
        -- trace ("ss  = " ++ show ss ) $ do
        -- trace ("ss' = " ++ show ss') $ do
        s' <- maybeToList ss'
        findName q s'
      where
        lookupName :: forall a. InScope a => C.Name -> Scope -> [(a, Access)]
        lookupName x s = fromMaybe [] $ Map.lookup x $ allNamesInScope' s

    -- 2. Finding a name in the top imports.

    topImports :: Maybe (a, Access)
    topImports = case (inScopeTag :: InScopeTag a) of
      NameTag   -> Nothing
      ModuleTag -> first (`AbsModule` Defined) <$> imported q

    imported :: C.QName -> Maybe (A.ModuleName, Access)
    imported q = fmap (,PublicAccess) $ Map.lookup q $ scopeImports root

    -- 3. Finding a name in the imports belonging to an initial part of the qualifier.

    imports :: [(a, Access)]
    imports = do
      (m, x) <- splitName q
      m <- maybeToList $ fst <$> imported m
      findName x $ restrictPrivate $ moduleScope m

    -- return all possible splittings, e.g.
    -- splitName X.Y.Z = [(X, Y.Z), (X.Y, Z)]
    splitName :: C.QName -> [(C.QName, C.QName)]
    splitName (C.QName x)  = []
    splitName (C.Qual x q) =
      (C.QName x, q) : [ (C.Qual x m, r) | (m, r) <- splitName q ]


-- * Inverse look-up

data AllowAmbiguousNames
  = AmbiguousAnything
      -- ^ Used for instance arguments to check whether a name is in scope,
      --   but we do not care whether is is ambiguous
  | AmbiguousConProjs
      -- ^ Ambiguous constructors, projections, or pattern synonyms.
  | AmbiguousNothing
  deriving (Eq)

isNameInScope :: A.QName -> ScopeInfo -> Bool
isNameInScope q scope =
  billToPure [ Scoping, InverseScopeLookup ] $
  Set.member q (scope ^. scopeInScope)

-- | Find the concrete names that map (uniquely) to a given abstract name.
--   Sort by length, shortest first.

inverseScopeLookup :: Either A.ModuleName A.QName -> ScopeInfo -> [C.QName]
inverseScopeLookup = inverseScopeLookup' AmbiguousConProjs

inverseScopeLookup' :: AllowAmbiguousNames -> Either A.ModuleName A.QName -> ScopeInfo -> [C.QName]
inverseScopeLookup' amb name scope = billToPure [ Scoping , InverseScopeLookup ] $
  case name of
    Left  m -> best $ filter unambiguousModule $ findModule m
    Right q -> best $ filter unambiguousName   $ findName q
  where
    findName   x = maybe [] toList $ Map.lookup x (scope ^. scopeInverseName)
    findModule x = fromMaybe []    $ Map.lookup x (scope ^. scopeInverseModule)

    len :: C.QName -> Int
    len (C.QName _)  = 1
    len (C.Qual _ x) = 1 + len x

    best :: [C.QName] -> [C.QName]
    best = List.sortBy (compare `on` len)

    unique :: forall a . [a] -> Bool
    unique []      = __IMPOSSIBLE__
    unique [_]     = True
    unique (_:_:_) = False

    unambiguousModule q = amb == AmbiguousAnything || unique (scopeLookup q scope :: [AbstractModule])
    unambiguousName   q = amb == AmbiguousAnything
        || unique xs
        || amb == AmbiguousConProjs
           && or [ all ((kind ==) . anameKind) xs | kind <- [ConName, FldName, PatternSynName] ]
      where xs = scopeLookup q scope

recomputeInverseScopeMaps :: ScopeInfo -> ScopeInfo
recomputeInverseScopeMaps scope = billToPure [ Scoping , InverseScopeLookup ] $
  scope { _scopeInverseName   = nameMap
        , _scopeInverseModule = Map.fromList [ (x, findModule x) | x <- Map.keys moduleMap ++ Map.keys importMap ]
        , _scopeInScope       = nsInScope $ everythingInScopeQualified scope
        }
  where
    this = scope ^. scopeCurrent
    current = this : scopeParents (moduleScope this)
    scopes  = [ (m, restrict m s) | (m, s) <- Map.toList (scope ^. scopeModules) ]

    moduleScope :: A.ModuleName -> Scope
    moduleScope m = fromMaybe __IMPOSSIBLE__ $ Map.lookup m $ scope ^. scopeModules

    restrict m s | m `elem` current = s
                 | otherwise = restrictPrivate s

    internalName :: C.QName -> Bool
    internalName C.QName{} = False
    internalName (C.Qual m n) = intern m || internalName n
      where
      -- Recognize fresh names created Parser.y
      intern (C.Name _ _ [ C.Id ('.' : '#' : _) ]) = True
      intern _ = False

    findName :: Ord a => Map a [(A.ModuleName, C.Name)] -> a -> [C.QName]
    findName table q = do
      (m, x) <- fromMaybe [] $ Map.lookup q table
      if m `elem` current
        then return (C.QName x)
        else do
          y <- findModule m
          let z = C.qualify y x
          guard $ not $ internalName z
          return z

    findModule :: A.ModuleName -> [C.QName]
    findModule q = findName moduleMap q ++
                   fromMaybe [] (Map.lookup q importMap)

    importMap = Map.fromListWith (++) $ do
      (m, s) <- scopes
      (x, y) <- Map.toList $ scopeImports s
      return (y, singleton x)

    moduleMap = Map.fromListWith (++) $ do
      (m, s)  <- scopes
      (x, ms) <- Map.toList (allNamesInScope s)
      q       <- amodName <$> ms
      return (q, singleton (m, x))

    nameMap :: NameMap
    nameMap = Map.fromListWith (Sgrp.<>) $ do
      (m, s)  <- scopes
      (x, ms) <- Map.toList (allNamesInScope s)
      q       <- anameName <$> ms
      if m `elem` current
        then return (q, singleton (C.QName x))
        else do
          y <- findModule m
          let z = C.qualify y x
          guard $ not $ internalName z
          return (q, singleton z)

-- | Find the concrete names that map (uniquely) to a given abstract qualified name.
--   Sort by length, shortest first.
inverseScopeLookupName :: A.QName -> ScopeInfo -> [C.QName]
inverseScopeLookupName x = inverseScopeLookup (Right x)

inverseScopeLookupName' :: AllowAmbiguousNames -> A.QName -> ScopeInfo -> [C.QName]
inverseScopeLookupName' ambCon x = inverseScopeLookup' ambCon (Right x)

-- | Find the concrete names that map (uniquely) to a given abstract module name.
--   Sort by length, shortest first.
inverseScopeLookupModule :: A.ModuleName -> ScopeInfo -> [C.QName]
inverseScopeLookupModule x = inverseScopeLookup (Left x)

------------------------------------------------------------------------
-- * (Debug) printing
------------------------------------------------------------------------

instance Pretty AbstractName where
  pretty = pretty . anameName

instance Pretty AbstractModule where
  pretty = pretty . amodName

instance Pretty NameSpaceId where
  pretty = text . \case
    PublicNS        -> "public"
    PrivateNS       -> "private"
    ImportedNS      -> "imported"
    OnlyQualifiedNS -> "only-qualified"

instance Pretty NameSpace where
  pretty = vcat . prettyNameSpace

prettyNameSpace :: NameSpace -> [Doc]
prettyNameSpace (NameSpace names mods _) =
    blockOfLines "names"   (map pr $ Map.toList names) ++
    blockOfLines "modules" (map pr $ Map.toList mods)
  where
    pr :: (Pretty a, Pretty b) => (a,b) -> Doc
    pr (x, y) = pretty x <+> "-->" <+> pretty y

instance Pretty Scope where
  pretty (scope@Scope{ scopeName = name, scopeParents = parents, scopeImports = imps }) =
    vcat $
      [ "scope" <+> pretty name ] ++ ind (
        concat [ blockOfLines (pretty nsid) $ prettyNameSpace ns
               | (nsid, ns) <- scopeNameSpaces scope ]
      ++ blockOfLines "imports"
           (case Map.keys imps of [] -> []; ks -> [ prettyList ks ])
      )
    where ind = map $ nest 2

-- | Add first string only if list is non-empty.
blockOfLines :: Doc -> [Doc] -> [Doc]
blockOfLines _  [] = []
blockOfLines hd ss = hd : map (nest 2) ss

instance Pretty ScopeInfo where
  pretty (ScopeInfo this mods toBind locals ctx _ _ _ _ _) = vcat $
    [ "ScopeInfo"
    , "  current = " <> pretty this
    ] ++
    (if null toBind then [] else [ "  toBind  = " <> pretty locals ]) ++
    (if null locals then [] else [ "  locals  = " <> pretty locals ]) ++
    [ "  context = " <> pretty ctx
    , "  modules"
    ] ++
    map (nest 4) (List.filter (not . null) $ map pretty $ Map.elems mods)

------------------------------------------------------------------------
-- * Boring instances
------------------------------------------------------------------------

instance KillRange ScopeInfo where
  killRange m = m

instance HasRange AbstractName where
  getRange = getRange . anameName

instance SetRange AbstractName where
  setRange r x = x { anameName = setRange r $ anameName x }
