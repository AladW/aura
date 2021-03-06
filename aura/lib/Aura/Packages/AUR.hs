{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts, TypeApplications, MonoLocalBinds #-}

-- |
-- Module    : Aura.Packages.AUR
-- Copyright : (c) Colin Woodbury, 2012 - 2018
-- License   : GPL3
-- Maintainer: Colin Woodbury <colin@fosskers.ca>
--
-- Module for connecting to the AUR servers, downloading PKGBUILDs and package sources.

module Aura.Packages.AUR
  ( -- * Batch Querying
    aurLookup
  , aurRepo
    -- * Single Querying
  , aurInfo
  , aurSearch
    -- * Source Retrieval
  , clone
  , pkgUrl
  ) where

import           Aura.Core
import           Aura.Pkgbuild.Base
import           Aura.Pkgbuild.Fetch
import           Aura.Settings
import           Aura.Types
import           Aura.Utils (quietSh)
import           BasePrelude hiding (FilePath, head)
import           Control.Compactable (traverseEither)
import           Control.Error.Util (hush)
import           Control.Monad.Freer
import           Control.Monad.Freer.Reader
import           Data.List.NonEmpty (head)
import qualified Data.Set as S
import           Data.Set.NonEmpty (NonEmptySet)
import qualified Data.Set.NonEmpty as NES
import qualified Data.Text as T
import           Data.Versions (versioning)
import           Linux.Arch.Aur
import           Network.HTTP.Client (Manager)
import qualified Shelly as Sh
import           System.FilePath ((</>))

---

-- | Attempt to retrieve info about a given `S.Set` of packages from the AUR.
-- This is a signature expected by `InstallOptions`.
aurLookup :: Settings -> NonEmptySet PkgName -> IO (S.Set PkgName, S.Set Buildable)
aurLookup ss names = do
  (bads, goods) <- info m (foldMap (\(PkgName pn) -> [pn]) names) >>= traverseEither (buildable m)
  let goodNames = S.fromList $ map bldNameOf goods
  pure (S.fromList bads <> NES.toSet names S.\\ goodNames, S.fromList goods)
    where m = managerOf ss

-- | Yield fully realized `Package`s from the AUR. This is the other signature
-- expected by `InstallOptions`.
aurRepo :: Repository
aurRepo = Repository $ \ss ps -> do
  (bads, goods) <- aurLookup ss ps
  pkgs <- traverse (packageBuildable ss) $ toList goods
  pure (bads, S.fromList pkgs)

buildable :: Manager -> AurInfo -> IO (Either PkgName Buildable)
buildable m ai = do
  let !bse = PkgName $ pkgBaseOf ai
  mpb <- pkgbuild m bse  -- Using the package base ensures split packages work correctly.
  case mpb of
    Nothing -> pure . Left . PkgName $ aurNameOf ai
    Just pb -> pure $ Right Buildable
      { bldNameOf     = PkgName $ aurNameOf ai
      , pkgbuildOf    = Pkgbuild pb
      , bldBaseNameOf = bse
      , bldProvidesOf = list (Provides $ aurNameOf ai) (Provides . head) $ providesOf ai
      -- TODO This is a potentially naughty mapMaybe, since deps that fail to parse
      -- will be silently dropped. Unfortunately there isn't much to be done - `aurLookup`
      -- and `aurRepo` which call this function only report existence errors
      -- (i.e. "this package couldn't be found at all").
      , bldDepsOf     = mapMaybe parseDep $ dependsOf ai ++ makeDepsOf ai
      , bldVersionOf  = hush . versioning $ aurVersionOf ai
      , isExplicit    = False }

----------------
-- AUR PKGBUILDS
----------------
aurLink :: T.Text
aurLink = "https://aur.archlinux.org"

-- | A package's home URL on the AUR.
pkgUrl :: PkgName -> T.Text
pkgUrl (PkgName pkg) = T.pack $ T.unpack aurLink </> "packages" </> T.unpack pkg

-------------------
-- SOURCES FROM GIT
-------------------
-- | Attempt to clone a package source from the AUR.
clone :: Buildable -> Sh.Sh (Maybe Sh.FilePath)
clone b = do
  (ec, _) <- quietSh $ Sh.run_ "git" ["clone", "--depth", "1", aurLink <> "/" <> _pkgname (bldBaseNameOf b) <> ".git"]
  case ec of
    (ExitFailure _) -> pure Nothing
    ExitSuccess     -> Just . (Sh.</> _pkgname (bldBaseNameOf b)) <$> Sh.pwd

------------
-- RPC CALLS
------------
sortAurInfo :: Maybe BuildSwitch -> [AurInfo] -> [AurInfo]
sortAurInfo bs ai = sortBy compare' ai
  where compare' = case bs of
                     Just SortAlphabetically -> compare `on` aurNameOf
                     _ -> \x y -> compare (aurVotesOf y) (aurVotesOf x)

-- | Frontend to the `aur` library. For @-As@.
aurSearch :: (Member (Reader Settings) r, Member IO r) => T.Text -> Eff r [AurInfo]
aurSearch regex = do
  ss  <- ask
  res <- send $ search @IO (managerOf ss) regex
  pure $ sortAurInfo (bool Nothing (Just SortAlphabetically) $ switch ss SortAlphabetically) res

-- | Frontend to the `aur` library. For @-Ai@.
aurInfo :: (Member (Reader Settings) r, Member IO r) => NonEmpty PkgName -> Eff r [AurInfo]
aurInfo pkgs = do
  m <- asks managerOf
  sortAurInfo (Just SortAlphabetically) <$> send (info @IO m . map _pkgname $ toList pkgs)
