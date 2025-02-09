{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

module Cardano.Api.Eon.ByronEraOnly
  ( ByronEraOnly(..)
  , byronEraOnlyConstraints
  , byronEraOnlyToCardanoEra

  , ByronEraOnlyConstraints
  ) where

import           Cardano.Api.Eras.Core

import           Data.Typeable (Typeable)

data ByronEraOnly era where
  ByronEraOnlyByron  :: ByronEraOnly ByronEra

deriving instance Show (ByronEraOnly era)
deriving instance Eq (ByronEraOnly era)

instance Eon ByronEraOnly where
  inEonForEra no yes = \case
    ByronEra    -> yes ByronEraOnlyByron
    ShelleyEra  -> no
    AllegraEra  -> no
    MaryEra     -> no
    AlonzoEra   -> no
    BabbageEra  -> no
    ConwayEra   -> no

instance ToCardanoEra ByronEraOnly where
  toCardanoEra = \case
    ByronEraOnlyByron  -> ByronEra

type ByronEraOnlyConstraints era =
  ( IsCardanoEra era
  , Typeable era
  )

byronEraOnlyConstraints :: ()
  => ByronEraOnly era
  -> (ByronEraOnlyConstraints era => a)
  -> a
byronEraOnlyConstraints = \case
  ByronEraOnlyByron  -> id

byronEraOnlyToCardanoEra :: ByronEraOnly era -> CardanoEra era
byronEraOnlyToCardanoEra = \case
  ByronEraOnlyByron  -> ByronEra
