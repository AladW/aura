{-# LANGUAGE FlexibleContexts, MonoLocalBinds #-}
{-# LANGUAGE MultiWayIf, OverloadedStrings #-}

-- |
-- Module    : Aura.Core
-- Copyright : (c) Colin Woodbury, 2012 - 2018
-- License   : GPL3
-- Maintainer: Colin Woodbury <colin@fosskers.ca>
--
-- Core types and functions which belong nowhere else.

module Aura.Core
  ( -- * Types
    Repository(..)
  , rethrow
    -- * User Privileges
  , sudo, trueRoot
    -- * Querying the Package Database
  , foreignPackages, orphans, develPkgs
  , isSatisfied, isInstalled
  , checkDBLock
    -- * Misc. Package Handling
  , removePkgs, partitionPkgs
    -- * IO
  , notify, warn, scold, report
  ) where

import           Aura.Colour
import           Aura.Languages
import           Aura.Pacman
import           Aura.Settings
import           Aura.Types
import           Aura.Utils
import           BasePrelude hiding ((<>))
import           Control.Compactable (fmapEither)
import           Control.Monad.Freer
import           Control.Monad.Freer.Error
import           Control.Monad.Freer.Reader
import qualified Data.List.NonEmpty as NEL
import           Data.Semigroup
import qualified Data.Set as S
import           Data.Set.NonEmpty (NonEmptySet)
import qualified Data.Set.NonEmpty as NES
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Text.Prettyprint.Doc
import           Data.Text.Prettyprint.Doc.Render.Terminal
import           Data.Versions (prettyV)
import           Shelly (Sh, test_f)

---

--------
-- TYPES
--------

-- | A `Repository` is a place where packages may be fetched from. Multiple
-- repositories can be combined with the `Semigroup` instance.
-- Checks packages in batches for efficiency.
newtype Repository = Repository { repoLookup :: Settings -> NonEmptySet PkgName -> IO (S.Set PkgName, S.Set Package) }

instance Semigroup Repository where
  a <> b = Repository $ \ss ps -> do
    (bads, goods) <- repoLookup a ss ps
    case NES.fromSet bads of
      Nothing    -> pure (bads, goods)
      Just bads' -> second (goods <>) <$> repoLookup b ss bads'

---------------------------------
-- Functions common to `Package`s
---------------------------------
-- | Partition a list of packages into pacman and buildable groups.
-- Yes, this is the correct signature. As far as this function (in isolation)
-- is concerned, there is no way to guarantee that the list of `NonEmptySet`s
-- will itself be non-empty.
partitionPkgs :: NonEmpty (NonEmptySet Package) -> ([PkgName], [NonEmptySet Buildable])
partitionPkgs = bimap fold f . unzip . fmap g . toList
  where g = fmapEither (toEither . _pkgInstallType) . toList
        f = mapMaybe (fmap NES.fromNonEmpty . NEL.nonEmpty)
        toEither (Pacman s) = Left  s
        toEither (Build  b) = Right b

-----------
-- THE WORK
-----------
-- | Lift a common return type into the `Eff` world. Usually used after a `pacman` call.
rethrow :: (Member (Error a) r, Member IO r) => IO (Either a b) -> Eff r b
rethrow = send >=> either throwError pure

-- | Action won't be allowed unless user is root, or using sudo.
sudo :: (Member (Reader Settings) r, Member (Error Failure) r) => Eff r a -> Eff r a
sudo action = asks (hasRootPriv . envOf) >>= bool (throwError $ Failure mustBeRoot_1) action

-- | Stop the user if they are the true root. Building as root isn't allowed
-- since makepkg v4.2.
trueRoot :: (Member (Reader Settings) r, Member (Error Failure) r) => Eff r a -> Eff r a
trueRoot action = ask >>= \ss ->
  if not (isTrueRoot $ envOf ss) && buildUserOf (buildConfigOf ss) /= Just (User "root")
    then action else throwError $ Failure trueRoot_3

-- | A list of non-prebuilt packages installed on the system.
-- `-Qm` yields a list of sorted values.
foreignPackages :: IO (S.Set SimplePkg)
foreignPackages = S.fromList . mapMaybe simplepkg' . T.lines <$> pacmanOutput ["-Qm"]

-- | Packages marked as a dependency, yet are required by no other package.
orphans :: IO (S.Set PkgName)
orphans = S.fromList . map PkgName . T.lines <$> pacmanOutput ["-Qqdt"]

-- | Any package whose name is suffixed by git, hg, svn, darcs, cvs, or bzr.
develPkgs :: IO (S.Set PkgName)
develPkgs = S.filter isDevelPkg . S.map _spName <$> foreignPackages
  where isDevelPkg (PkgName pkg) = any (`T.isSuffixOf` pkg) suffixes
        suffixes = ["-git", "-hg", "-svn", "-darcs", "-cvs", "-bzr"]

-- | Returns what it was given if the package is already installed.
-- Reasoning: Using raw bools can be less expressive.
isInstalled :: PkgName -> IO (Maybe PkgName)
isInstalled pkg = bool Nothing (Just pkg) <$> pacmanSuccess ["-Qq", _pkgname pkg]

-- | An @-Rsu@ call.
removePkgs :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) => NonEmptySet PkgName -> Eff r ()
removePkgs pkgs = do
  pacOpts <- asks (asFlag . commonConfigOf)
  rethrow . pacman $ ["-Rsu"] <> asFlag pkgs <> pacOpts

-- | True if a dependency is satisfied by an installed package.
-- `asT` renders the `VersionDemand` into the specific form that `pacman -T`
-- understands. See `man pacman` for more info.
isSatisfied :: Dep -> IO Bool
isSatisfied (Dep name ver) = T.null <$> pacmanOutput ["-T", _pkgname name <> asT ver]
  where asT (LessThan v) = "<"  <> prettyV v
        asT (AtLeast  v) = ">=" <> prettyV v
        asT (MoreThan v) = ">"  <> prettyV v
        asT (MustBe   v) = "="  <> prettyV v
        asT Anything     = ""

-- | Block further action until the database is free.
checkDBLock :: Settings -> Sh ()
checkDBLock ss = do
  locked <- test_f lockFile
  when locked $ (liftIO . warn ss . checkDBLock_1 $ langOf ss) *> liftIO getLine *> checkDBLock ss

-------
-- MISC  -- Too specific for `Utilities.hs` or `Aura.Utils`
-------

-- | Print some message in green with Aura flair.
notify :: Settings -> Doc AnsiStyle -> IO ()
notify ss = putStrLnA ss . green

-- | Print some message in yellow with Aura flair.
warn :: Settings -> Doc AnsiStyle -> IO ()
warn ss = putStrLnA ss . yellow

-- | Print some message in red with Aura flair.
scold :: Settings -> Doc AnsiStyle -> IO ()
scold ss = putStrLnA ss . red

-- | Report a message with multiple associated items. Usually a list of
-- naughty packages.
report :: (Member (Reader Settings) r, Member IO r) =>
  (Doc AnsiStyle -> Doc AnsiStyle) -> (Language -> Doc AnsiStyle) -> NonEmpty PkgName -> Eff r ()
report c msg pkgs = do
  ss <- ask
  send . putStrLnA ss . c . msg $ langOf ss
  send . T.putStrLn . dtot . colourCheck ss . vsep . map (cyan . pretty . _pkgname) $ toList pkgs
