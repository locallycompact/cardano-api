{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

-- | Ledger CDDL Serialisation
--
module Cardano.Api.SerialiseLedgerCddl
  ( TextEnvelopeCddl(..)
  , TextEnvelopeCddlError (..)
  , FromSomeTypeCDDL(..)

  -- * Reading one of several transaction or
  -- key witness types
  , readFileTextEnvelopeCddlAnyOf
  , deserialiseFromTextEnvelopeCddlAnyOf

  , writeTxFileTextEnvelopeCddl
  , writeTxWitnessFileTextEnvelopeCddl

  -- Exported for testing
  , serialiseTxLedgerCddl
  , deserialiseTxLedgerCddl
  , serialiseWitnessLedgerCddl
  , deserialiseWitnessLedgerCddl
  )
  where

import           Cardano.Api.Eon.ShelleyBasedEra
import           Cardano.Api.Eras
import           Cardano.Api.Error
import           Cardano.Api.HasTypeProxy
import           Cardano.Api.IO
import           Cardano.Api.SerialiseCBOR
import           Cardano.Api.Tx
import           Cardano.Api.Utils

import           Cardano.Ledger.Binary (DecoderError)
import qualified Cardano.Ledger.Binary as CBOR

import           Control.Monad.Trans.Except.Extra (firstExceptT, handleIOExceptT, hoistEither,
                   newExceptT, runExceptT)
import           Data.Aeson
import qualified Data.Aeson as Aeson
import           Data.Aeson.Encode.Pretty (Config (..), defConfig, encodePretty', keyOrder)
import           Data.Bifunctor (first)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as LBS
import           Data.Data (Data)
import qualified Data.List as List
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text


-- Why have we gone this route? The serialization format of `TxBody era`
-- differs from the CDDL. We serialize to an intermediate type in order to simplify
-- the specification of Plutus scripts and to avoid users having to think about
-- and construct redeemer pointers. However it turns out we can still serialize to
-- the ledger's CDDL format and maintain the convenient script witness specification
-- that the cli commands build and build-raw expose.
--
-- The long term plan is to have all relevant outputs from the cli to adhere to
-- the ledger's CDDL spec. Modifying the existing TextEnvelope machinery to encompass
-- this would result in a lot of unnecessary changes where the serialization
-- already defaults to the CDDL spec. In order to reduce the number of changes, and to
-- ease removal of the non-CDDL spec serialization, we have opted to create a separate
-- data type to encompass this in the interim.

data TextEnvelopeCddl = TextEnvelopeCddl
  { teCddlType :: !Text
  , teCddlDescription :: !Text
  , teCddlRawCBOR :: !ByteString
  } deriving (Eq, Show)

instance ToJSON TextEnvelopeCddl where
  toJSON TextEnvelopeCddl {teCddlType, teCddlDescription, teCddlRawCBOR} =
    object [ "type"        .= teCddlType
           , "description" .= teCddlDescription
           , "cborHex"     .= Text.decodeUtf8 (Base16.encode teCddlRawCBOR)
           ]

instance FromJSON TextEnvelopeCddl where
  parseJSON = withObject "TextEnvelopeCddl" $ \v ->
                TextEnvelopeCddl <$> (v .: "type")
                                 <*> (v .: "description")
                                 <*> (parseJSONBase16 =<< v .: "cborHex")
    where
      parseJSONBase16 v =
        either fail return . Base16.decode . Text.encodeUtf8 =<< parseJSON v


data TextEnvelopeCddlError
  = TextEnvelopeCddlErrCBORDecodingError DecoderError
  | TextEnvelopeCddlAesonDecodeError FilePath String
  | TextEnvelopeCddlUnknownKeyWitness
  | TextEnvelopeCddlTypeError
      [Text] -- ^ Expected types
      Text   -- ^ Actual types
  | TextEnvelopeCddlErrUnknownType Text
  | TextEnvelopeCddlErrByronKeyWitnessUnsupported
  deriving (Show, Eq, Data)

instance Error TextEnvelopeCddlError where
  displayError (TextEnvelopeCddlErrCBORDecodingError decoderError) =
    "TextEnvelopeCDDL CBOR decoding error: " <> show decoderError
  displayError (TextEnvelopeCddlAesonDecodeError fp aesonErr) =
    "Could not JSON decode TextEnvelopeCddl file at: " <> fp <> " Error: " <> aesonErr
  displayError TextEnvelopeCddlUnknownKeyWitness =
    "Unknown key witness specified"
  displayError (TextEnvelopeCddlTypeError expTypes actType) =
    "TextEnvelopeCddl type error: "
       <> " Expected one of: "
       <> List.intercalate ", " (map Text.unpack expTypes)
       <> " Actual: " <> Text.unpack actType
  displayError (TextEnvelopeCddlErrUnknownType unknownType) =
    "Unknown TextEnvelopeCddl type: " <> Text.unpack unknownType
  displayError TextEnvelopeCddlErrByronKeyWitnessUnsupported =
    "TextEnvelopeCddl error: Byron key witnesses are currently unsupported."

serialiseTxLedgerCddl :: CardanoEra era -> Tx era -> TextEnvelopeCddl
serialiseTxLedgerCddl era tx =
  cardanoEraConstraints era $
    TextEnvelopeCddl
      { teCddlType = genType tx
      , teCddlDescription = "Ledger Cddl Format"
      , teCddlRawCBOR = serialiseToCBOR tx
      -- The SerialiseAsCBOR (Tx era) instance serializes to the Cddl format
      }
 where
  genType :: Tx era -> Text
  genType tx' = case getTxWitnesses tx' of
                  [] -> "Unwitnessed " <> genTxType
                  _ -> "Witnessed " <> genTxType
  genTxType :: Text
  genTxType =
    case era of
      ByronEra -> "Tx ByronEra"
      ShelleyEra -> "Tx ShelleyEra"
      AllegraEra -> "Tx AllegraEra"
      MaryEra -> "Tx MaryEra"
      AlonzoEra -> "Tx AlonzoEra"
      BabbageEra -> "Tx BabbageEra"
      ConwayEra -> "Tx ConwayEra"

deserialiseTxLedgerCddl :: ()
  => CardanoEra era
  -> TextEnvelopeCddl
  -> Either TextEnvelopeCddlError (Tx era)
deserialiseTxLedgerCddl era tec =
  first TextEnvelopeCddlErrCBORDecodingError . deserialiseTx era $ teCddlRawCBOR tec

deserialiseTx :: ()
  => CardanoEra era
  -> ByteString
  -> Either DecoderError (Tx era)
deserialiseTx era bs =
  caseByronOrShelleyBasedEra
    (\w -> ByronTx w <$> CBOR.decodeFullAnnotatedBytes CBOR.byronProtVer "Byron Tx" CBOR.decCBOR (LBS.fromStrict bs))
    (const $ cardanoEraConstraints era $ deserialiseFromCBOR (AsTx (proxyToAsType Proxy)) bs)
    era

serialiseWitnessLedgerCddl :: forall era. ShelleyBasedEra era -> KeyWitness era -> TextEnvelopeCddl
serialiseWitnessLedgerCddl sbe kw =
  TextEnvelopeCddl
    { teCddlType = witEra sbe
    , teCddlDescription = genDesc kw
    , teCddlRawCBOR = cddlSerialiseWitness kw
    }
 where
  cddlSerialiseWitness :: KeyWitness era -> ByteString
  cddlSerialiseWitness (ShelleyBootstrapWitness era wit) = CBOR.serialize' (eraProtVerLow era) wit
  cddlSerialiseWitness (ShelleyKeyWitness era wit) = CBOR.serialize' (eraProtVerLow era) wit
  cddlSerialiseWitness ByronKeyWitness{} = case sbe of {}

  genDesc :: KeyWitness era -> Text
  genDesc ByronKeyWitness{} = case sbe of {}
  genDesc ShelleyBootstrapWitness{} = "Key BootstrapWitness ShelleyEra"
  genDesc ShelleyKeyWitness{} = "Key Witness ShelleyEra"

  witEra :: ShelleyBasedEra era -> Text
  witEra ShelleyBasedEraShelley = "TxWitness ShelleyEra"
  witEra ShelleyBasedEraAllegra = "TxWitness AllegraEra"
  witEra ShelleyBasedEraMary = "TxWitness MaryEra"
  witEra ShelleyBasedEraAlonzo = "TxWitness AlonzoEra"
  witEra ShelleyBasedEraBabbage = "TxWitness BabbageEra"
  witEra ShelleyBasedEraConway = "TxWitness ConwayEra"

deserialiseWitnessLedgerCddl
  :: ShelleyBasedEra era
  -> TextEnvelopeCddl
  -> Either TextEnvelopeCddlError (KeyWitness era)
deserialiseWitnessLedgerCddl sbe TextEnvelopeCddl{teCddlRawCBOR,teCddlDescription} =
  --TODO: Parse these into types because this will increase code readability and
  -- will make it easier to keep track of the different Cddl descriptions via
  -- a single sum data type.
  case teCddlDescription of
    "Key BootstrapWitness ShelleyEra" -> do
      w <- first TextEnvelopeCddlErrCBORDecodingError
             $ CBOR.decodeFullAnnotator
               (eraProtVerLow sbe) "Shelley Witness" CBOR.decCBOR (LBS.fromStrict teCddlRawCBOR)
      Right $ ShelleyBootstrapWitness sbe w
    "Key Witness ShelleyEra" -> do
      w <- first TextEnvelopeCddlErrCBORDecodingError
             $ CBOR.decodeFullAnnotator
               (eraProtVerLow sbe) "Shelley Witness" CBOR.decCBOR (LBS.fromStrict teCddlRawCBOR)
      Right $ ShelleyKeyWitness sbe w
    _ -> Left TextEnvelopeCddlUnknownKeyWitness

writeTxFileTextEnvelopeCddl :: ()
  => CardanoEra era
  -> File content Out
  -> Tx era
  -> IO (Either (FileError ()) ())
writeTxFileTextEnvelopeCddl era path tx =
  runExceptT $ do
    handleIOExceptT (FileIOError (unFile path)) $ LBS.writeFile (unFile path) txJson
  where
    txJson = encodePretty' textEnvelopeCddlJSONConfig (serialiseTxLedgerCddl era tx) <> "\n"

writeTxWitnessFileTextEnvelopeCddl
  :: ShelleyBasedEra era
  -> File () Out
  -> KeyWitness era
  -> IO (Either (FileError ()) ())
writeTxWitnessFileTextEnvelopeCddl sbe path w =
  runExceptT $ do
    handleIOExceptT (FileIOError (unFile path)) $ LBS.writeFile (unFile path) txJson
  where
    txJson = encodePretty' textEnvelopeCddlJSONConfig (serialiseWitnessLedgerCddl sbe w) <> "\n"

textEnvelopeCddlJSONConfig :: Config
textEnvelopeCddlJSONConfig =
  defConfig { confCompare = textEnvelopeCddlJSONKeyOrder }

textEnvelopeCddlJSONKeyOrder :: Text -> Text -> Ordering
textEnvelopeCddlJSONKeyOrder = keyOrder ["type", "description", "cborHex"]

-- | This GADT allows us to deserialise a tx or key witness without
-- having to provide the era.
data FromSomeTypeCDDL c b where
  FromCDDLTx
    :: Text -- ^ CDDL type that we want
    -> (InAnyCardanoEra Tx -> b)
    -> FromSomeTypeCDDL TextEnvelopeCddl b

  FromCDDLWitness
    :: Text -- ^ CDDL type that we want
    -> (InAnyCardanoEra KeyWitness -> b)
    -> FromSomeTypeCDDL TextEnvelopeCddl b

deserialiseFromTextEnvelopeCddlAnyOf
  :: [FromSomeTypeCDDL TextEnvelopeCddl b]
  -> TextEnvelopeCddl
  -> Either TextEnvelopeCddlError b
deserialiseFromTextEnvelopeCddlAnyOf types teCddl =
    case List.find matching types of
      Nothing ->
        Left (TextEnvelopeCddlTypeError expectedTypes actualType)

      Just (FromCDDLTx ttoken f) -> do
        AnyCardanoEra era <- cddlTypeToEra ttoken
        f . InAnyCardanoEra era <$> deserialiseTxLedgerCddl era teCddl

      Just (FromCDDLWitness ttoken f) -> do
         AnyCardanoEra era <- cddlTypeToEra ttoken
         case cardanoEraStyle era of
           LegacyByronEra -> Left TextEnvelopeCddlErrByronKeyWitnessUnsupported
           ShelleyBasedEra sbe ->
             f . InAnyCardanoEra era <$> deserialiseWitnessLedgerCddl sbe teCddl
  where
   actualType :: Text
   actualType = teCddlType teCddl

   expectedTypes :: [Text]
   expectedTypes = [ typ | FromCDDLTx typ _f <- types ]

   matching :: FromSomeTypeCDDL TextEnvelopeCddl b -> Bool
   matching (FromCDDLTx ttoken _f) = actualType == ttoken
   matching (FromCDDLWitness ttoken _f)  = actualType == ttoken

-- Parse the text into types because this will increase code readability and
-- will make it easier to keep track of the different Cddl descriptions via
-- a single sum data type.
cddlTypeToEra :: Text -> Either TextEnvelopeCddlError AnyCardanoEra
cddlTypeToEra "Witnessed Tx ByronEra" = return $ AnyCardanoEra ByronEra
cddlTypeToEra "Witnessed Tx ShelleyEra" = return $ AnyCardanoEra ShelleyEra
cddlTypeToEra "Witnessed Tx AllegraEra" = return $ AnyCardanoEra AllegraEra
cddlTypeToEra "Witnessed Tx MaryEra" = return $ AnyCardanoEra MaryEra
cddlTypeToEra "Witnessed Tx AlonzoEra" = return $ AnyCardanoEra AlonzoEra
cddlTypeToEra "Witnessed Tx BabbageEra" = return $ AnyCardanoEra BabbageEra
cddlTypeToEra "Witnessed Tx ConwayEra" = return $ AnyCardanoEra ConwayEra
cddlTypeToEra "Unwitnessed Tx ByronEra" = return $ AnyCardanoEra ByronEra
cddlTypeToEra "Unwitnessed Tx ShelleyEra" = return $ AnyCardanoEra ShelleyEra
cddlTypeToEra "Unwitnessed Tx AllegraEra" = return $ AnyCardanoEra AllegraEra
cddlTypeToEra "Unwitnessed Tx MaryEra" = return $ AnyCardanoEra MaryEra
cddlTypeToEra "Unwitnessed Tx AlonzoEra" = return $ AnyCardanoEra AlonzoEra
cddlTypeToEra "Unwitnessed Tx BabbageEra" = return $ AnyCardanoEra BabbageEra
cddlTypeToEra "Unwitnessed Tx ConwayEra" = return $ AnyCardanoEra ConwayEra
cddlTypeToEra "TxWitness ShelleyEra" = return $ AnyCardanoEra ShelleyEra
cddlTypeToEra "TxWitness AllegraEra" = return $ AnyCardanoEra AllegraEra
cddlTypeToEra "TxWitness MaryEra" = return $ AnyCardanoEra MaryEra
cddlTypeToEra "TxWitness AlonzoEra" = return $ AnyCardanoEra AlonzoEra
cddlTypeToEra "TxWitness BabbageEra" = return $ AnyCardanoEra BabbageEra
cddlTypeToEra "TxWitness ConwayEra" = return $ AnyCardanoEra ConwayEra
cddlTypeToEra unknownCddlType = Left $ TextEnvelopeCddlErrUnknownType unknownCddlType

readFileTextEnvelopeCddlAnyOf
  :: [FromSomeTypeCDDL TextEnvelopeCddl b]
  -> FilePath
  -> IO (Either (FileError TextEnvelopeCddlError) b)
readFileTextEnvelopeCddlAnyOf types path =
  runExceptT $ do
    te <- newExceptT $ readTextEnvelopeCddlFromFile path
    firstExceptT (FileError path) $ hoistEither $ do
      deserialiseFromTextEnvelopeCddlAnyOf types te

readTextEnvelopeCddlFromFile
  :: FilePath
  -> IO (Either (FileError TextEnvelopeCddlError) TextEnvelopeCddl)
readTextEnvelopeCddlFromFile path =
  runExceptT $ do
    bs <- fileIOExceptT path readFileBlocking
    firstExceptT (FileError path . TextEnvelopeCddlAesonDecodeError path)
      . hoistEither $ Aeson.eitherDecodeStrict' bs
