{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{- HLINT ignore "Redundant fmap" -}

module Cardano.Api.LedgerState
  ( -- * Initialization / Accumulation
    envSecurityParam
  , LedgerState
    ( ..
    , LedgerStateByron
    , LedgerStateShelley
    , LedgerStateAllegra
    , LedgerStateMary
    , LedgerStateAlonzo
    , LedgerStateBabbage
    , LedgerStateConway
    )
  , encodeLedgerState
  , decodeLedgerState
  , initialLedgerState
  , applyBlock
  , ValidationMode (..)
  , applyBlockWithEvents
  , AnyNewEpochState (..)
  , getAnyNewEpochState

    -- * Traversing the block chain
  , foldBlocks
  , FoldStatus (..)
  , chainSyncClientWithLedgerState
  , chainSyncClientPipelinedWithLedgerState

    -- * Ledger state conditions
  , ConditionResult (..)
  , fromConditionResult
  , toConditionResult
  , foldEpochState

    -- * Errors
  , LedgerStateError (..)
  , FoldBlocksError (..)
  , GenesisConfigError (..)
  , InitialLedgerStateError (..)

    -- * Leadership schedule
  , LeadershipError (..)
  , constructGlobals
  , currentEpochEligibleLeadershipSlots
  , nextEpochEligibleLeadershipSlots

    -- * Node Config
  , NodeConfig (..)

    -- ** Network Config
  , NodeConfigFile
  , readNodeConfig

    -- ** Genesis Config
  , GenesisConfig (..)
  , readCardanoGenesisConfig
  , mkProtocolInfoCardano

    -- *** Byron Genesis Config
  , readByronGenesisConfig

    -- *** Shelley Genesis Config
  , ShelleyConfig (..)
  , GenesisHashShelley (..)
  , readShelleyGenesisConfig
  , shelleyPraosNonce

    -- *** Alonzo Genesis Config
  , GenesisHashAlonzo (..)
  , readAlonzoGenesisConfig

    -- *** Conway Genesis Config
  , GenesisHashConway (..)
  , readConwayGenesisConfig

    -- ** Environment
  , Env (..)
  , genesisConfigToEnv
  )
where

import           Cardano.Api.Block
import           Cardano.Api.Certificate
import           Cardano.Api.Eon.ShelleyBasedEra
import           Cardano.Api.Eras.Case
import           Cardano.Api.Eras.Core (CardanoEra, forEraMaybeEon)
import           Cardano.Api.Error as Api
import           Cardano.Api.Genesis
import           Cardano.Api.IO
import           Cardano.Api.IPC (ConsensusModeParams (..),
                   LocalChainSyncClient (LocalChainSyncClientPipelined),
                   LocalNodeClientProtocols (..), LocalNodeClientProtocolsInMode,
                   LocalNodeConnectInfo (..), connectToLocalNode)
import           Cardano.Api.Keys.Praos
import           Cardano.Api.LedgerEvents.ConvertLedgerEvent
import           Cardano.Api.LedgerEvents.LedgerEvent
import           Cardano.Api.Modes (EpochSlots (..))
import qualified Cardano.Api.Modes as Api
import           Cardano.Api.Monad.Error
import           Cardano.Api.NetworkId (NetworkId (..), NetworkMagic (NetworkMagic))
import           Cardano.Api.Pretty
import           Cardano.Api.Query (CurrentEpochState (..), PoolDistribution (unPoolDistr),
                   ProtocolState, SerialisedCurrentEpochState (..), SerialisedPoolDistribution,
                   decodeCurrentEpochState, decodePoolDistribution, decodeProtocolState)
import qualified Cardano.Api.ReexposeLedger as Ledger
import           Cardano.Api.SpecialByron as Byron
import           Cardano.Api.Utils (textShow)

import qualified Cardano.Binary as CBOR
import qualified Cardano.Chain.Genesis
import qualified Cardano.Chain.Update
import           Cardano.Crypto (ProtocolMagicId (unProtocolMagicId), RequiresNetworkMagic (..))
import qualified Cardano.Crypto.Hash.Blake2b
import qualified Cardano.Crypto.Hash.Class
import qualified Cardano.Crypto.Hashing
import qualified Cardano.Crypto.ProtocolMagic
import qualified Cardano.Crypto.VRF as Crypto
import qualified Cardano.Crypto.VRF.Class as VRF
import           Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis (..))
import qualified Cardano.Ledger.Api.Era as Ledger
import qualified Cardano.Ledger.Api.Transition as Ledger
import           Cardano.Ledger.BaseTypes (Globals (..), Nonce, ProtVer (..), natVersion, (⭒))
import qualified Cardano.Ledger.BaseTypes as Ledger
import qualified Cardano.Ledger.BHeaderView as Ledger
import           Cardano.Ledger.Binary (DecoderError)
import qualified Cardano.Ledger.Coin as SL
import           Cardano.Ledger.Conway.Genesis (ConwayGenesis (..))
import qualified Cardano.Ledger.Keys as SL
import qualified Cardano.Ledger.PoolDistr as SL
import qualified Cardano.Ledger.Shelley.API as ShelleyAPI
import qualified Cardano.Ledger.Shelley.Core as Core
import qualified Cardano.Ledger.Shelley.Genesis as Ledger
import qualified Cardano.Protocol.TPraos.API as TPraos
import           Cardano.Protocol.TPraos.BHeader (checkLeaderNatValue)
import qualified Cardano.Protocol.TPraos.BHeader as TPraos
import           Cardano.Slotting.EpochInfo (EpochInfo)
import qualified Cardano.Slotting.EpochInfo.API as Slot
import           Cardano.Slotting.Slot (WithOrigin (At, Origin))
import qualified Cardano.Slotting.Slot as Slot
import qualified Ouroboros.Consensus.Block.Abstract as Consensus
import           Ouroboros.Consensus.Block.Forging (BlockForging)
import qualified Ouroboros.Consensus.Byron.Ledger as Byron
import qualified Ouroboros.Consensus.Cardano as Consensus
import qualified Ouroboros.Consensus.Cardano.Block as Consensus
import qualified Ouroboros.Consensus.Cardano.CanHardFork as Consensus
import qualified Ouroboros.Consensus.Cardano.Node as Consensus
import qualified Ouroboros.Consensus.Config as Consensus
import qualified Ouroboros.Consensus.HardFork.Combinator as Consensus
import qualified Ouroboros.Consensus.HardFork.Combinator.AcrossEras as HFC
import qualified Ouroboros.Consensus.HardFork.Combinator.Basics as HFC
import qualified Ouroboros.Consensus.Ledger.Abstract as Ledger
import qualified Ouroboros.Consensus.Ledger.Extended as Ledger
import qualified Ouroboros.Consensus.Mempool.Capacity as TxLimits
import qualified Ouroboros.Consensus.Node.ProtocolInfo as Consensus
import           Ouroboros.Consensus.Protocol.Abstract (ChainDepState, ConsensusProtocol (..))
import qualified Ouroboros.Consensus.Protocol.Praos.Common as Consensus
import           Ouroboros.Consensus.Protocol.Praos.VRF (mkInputVRF, vrfLeaderValue)
import qualified Ouroboros.Consensus.Shelley.HFEras as Shelley
import qualified Ouroboros.Consensus.Shelley.Ledger.Ledger as Shelley
import qualified Ouroboros.Consensus.Shelley.Ledger.Query.Types as Consensus
import           Ouroboros.Consensus.Storage.Serialisation
import           Ouroboros.Consensus.TypeFamilyWrappers (WrapLedgerEvent (WrapLedgerEvent))
import           Ouroboros.Network.Block (blockNo)
import qualified Ouroboros.Network.Block
import           Ouroboros.Network.Mux (MuxError)
import qualified Ouroboros.Network.Protocol.ChainSync.Client as CS
import qualified Ouroboros.Network.Protocol.ChainSync.ClientPipelined as CSP
import           Ouroboros.Network.Protocol.ChainSync.PipelineDecision

import           Control.Concurrent
import           Control.DeepSeq
import           Control.Error.Util (note)
import           Control.Exception.Safe
import           Control.Monad
import           Control.Monad.State.Strict
import           Data.Aeson as Aeson (FromJSON (parseJSON), Object, eitherDecodeStrict', withObject,
                   (.:), (.:?))
import           Data.Aeson.Types (Parser)
import           Data.Bifunctor
import           Data.ByteArray (ByteArrayAccess)
import qualified Data.ByteArray
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as LBS
import           Data.ByteString.Short as BSS
import           Data.Foldable
import           Data.IORef
import qualified Data.List as List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import           Data.Proxy (Proxy (Proxy))
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.SOP.Strict.NP
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Lazy as LT
import           Data.Text.Lazy.Builder (toLazyText)
import           Data.Word
import qualified Data.Yaml as Yaml
import           Formatting.Buildable (build)
import           Lens.Micro
import           Network.TypedProtocol.Pipelined (Nat (..))
import           System.FilePath

data InitialLedgerStateError
  = -- | Failed to read or parse the network config file.
    ILSEConfigFile Text
  | -- | Failed to read or parse a genesis file linked from the network config file.
    ILSEGenesisFile GenesisConfigError
  | -- | Failed to derive the Ledger or Consensus config.
    ILSELedgerConsensusConfig GenesisConfigError
  deriving Show

instance Exception InitialLedgerStateError

instance Error InitialLedgerStateError where
  prettyError = \case
    ILSEConfigFile err ->
      "Failed to read or parse the network config file:" <+> pretty err
    ILSEGenesisFile err ->
      "Failed to read or parse a genesis file linked from the network config file:" <+> prettyError err
    ILSELedgerConsensusConfig err ->
      "Failed to derive the Ledger or Consensus config:" <+> prettyError err

data LedgerStateError
  = -- | When using QuickValidation, the block hash did not match the expected
    -- block hash after applying a new block to the current ledger state.
    ApplyBlockHashMismatch Text
  | -- | When using FullValidation, an error occurred when applying a new block
    -- to the current ledger state.
    ApplyBlockError (Consensus.CardanoLedgerError Consensus.StandardCrypto)
  | -- | Encountered a rollback larger than the security parameter.
    InvalidRollback
      SlotNo
      -- ^ Oldest known slot number that we can roll back to.
      ChainPoint
      -- ^ Rollback was attempted to this point.
  | -- | The ledger state condition you were interested in was not met
    -- prior to the termination epoch.
    TerminationEpochReached EpochNo
  | UnexpectedLedgerState
      AnyShelleyBasedEra
      -- ^ Expected era
      (Consensus.CardanoLedgerState Consensus.StandardCrypto)
      -- ^ Ledgerstate from an unexpected era
  | ByronEraUnsupported
  | DebugError !String
  deriving Show

instance Exception LedgerStateError

instance Error LedgerStateError where
  prettyError = \case
    DebugError e -> pretty e
    ApplyBlockHashMismatch err -> "Applying a block did not result in the expected block hash:" <+> pretty err
    ApplyBlockError hardForkLedgerError -> "Applying a block resulted in an error:" <+> pshow hardForkLedgerError
    InvalidRollback oldestSupported rollbackPoint ->
      "Encountered a rollback larger than the security parameter. Attempted to roll back to"
        <+> pshow rollbackPoint
        <> ", but oldest supported slot is"
          <+> pshow oldestSupported
    TerminationEpochReached epochNo ->
      mconcat
        [ "The ledger state condition you were interested in was not met "
        , "prior to the termination epoch:" <+> pshow epochNo
        ]
    UnexpectedLedgerState expectedEra unexpectedLS ->
      mconcat
        [ "Expected ledger state from the "
        , pshow expectedEra
        , " era, but got "
        , pshow unexpectedLS
        ]
    ByronEraUnsupported -> "Byron era is not supported"

-- | Get the environment and initial ledger state.
initialLedgerState
  :: MonadIOTransError InitialLedgerStateError t m
  => NodeConfigFile 'In
  -- ^ Path to the cardano-node config file (e.g. <path to cardano-node project>/configuration/cardano/mainnet-config.json)
  -> t m (Env, LedgerState)
  -- ^ The environment and initial ledger state
initialLedgerState nodeConfigFile = do
  -- TODO Once support for querying the ledger config is added to the node, we
  -- can remove the nodeConfigFile argument and much of the code in this
  -- module.
  config <- modifyError ILSEConfigFile (readNodeConfig nodeConfigFile)
  genesisConfig <- modifyError ILSEGenesisFile (readCardanoGenesisConfig Nothing config)
  env <- modifyError ILSELedgerConsensusConfig (except (genesisConfigToEnv genesisConfig))
  let ledgerState = initLedgerStateVar genesisConfig
  return (env, ledgerState)

-- | Apply a single block to the current ledger state.
applyBlock
  :: Env
  -- ^ The environment returned by @initialLedgerState@
  -> LedgerState
  -- ^ The current ledger state
  -> ValidationMode
  -> BlockInMode
  -- ^ Some block to apply
  -> Either LedgerStateError (LedgerState, [LedgerEvent])
  -- ^ The new ledger state (or an error).
applyBlock env oldState validationMode =
  applyBlock' env oldState validationMode . toConsensusBlock

pattern LedgerStateByron
  :: Ledger.LedgerState Byron.ByronBlock
  -> LedgerState
pattern LedgerStateByron st <- LedgerState (Consensus.LedgerStateByron st)

pattern LedgerStateShelley
  :: Ledger.LedgerState Shelley.StandardShelleyBlock
  -> LedgerState
pattern LedgerStateShelley st <- LedgerState (Consensus.LedgerStateShelley st)

pattern LedgerStateAllegra
  :: Ledger.LedgerState Shelley.StandardAllegraBlock
  -> LedgerState
pattern LedgerStateAllegra st <- LedgerState (Consensus.LedgerStateAllegra st)

pattern LedgerStateMary
  :: Ledger.LedgerState Shelley.StandardMaryBlock
  -> LedgerState
pattern LedgerStateMary st <- LedgerState (Consensus.LedgerStateMary st)

pattern LedgerStateAlonzo
  :: Ledger.LedgerState Shelley.StandardAlonzoBlock
  -> LedgerState
pattern LedgerStateAlonzo st <- LedgerState (Consensus.LedgerStateAlonzo st)

pattern LedgerStateBabbage
  :: Ledger.LedgerState Shelley.StandardBabbageBlock
  -> LedgerState
pattern LedgerStateBabbage st <- LedgerState (Consensus.LedgerStateBabbage st)

pattern LedgerStateConway
  :: Ledger.LedgerState Shelley.StandardConwayBlock
  -> LedgerState
pattern LedgerStateConway st <- LedgerState (Consensus.LedgerStateConway st)

{-# COMPLETE
  LedgerStateByron
  , LedgerStateShelley
  , LedgerStateAllegra
  , LedgerStateMary
  , LedgerStateAlonzo
  , LedgerStateBabbage
  , LedgerStateConway
  #-}

data FoldBlocksError
  = FoldBlocksInitialLedgerStateError !InitialLedgerStateError
  | FoldBlocksApplyBlockError !LedgerStateError
  | FoldBlocksIOException !IOException
  | FoldBlocksMuxError !MuxError
  deriving Show

instance Error FoldBlocksError where
  prettyError = \case
    FoldBlocksInitialLedgerStateError err -> prettyError err
    FoldBlocksApplyBlockError err -> "Failed when applying a block:" <+> prettyError err
    FoldBlocksIOException err -> "IOException:" <+> prettyException err
    FoldBlocksMuxError err -> "FoldBlocks error:" <+> prettyException err

-- | Type that lets us decide whether to continue or stop
-- the fold from within our accumulation function.
data FoldStatus
  = ContinueFold
  | StopFold
  | DebugFold
  deriving (Show, Eq)

-- | Monadic fold over all blocks and ledger states. Stopping @k@ blocks before
-- the node's tip where @k@ is the security parameter.
foldBlocks
  :: forall a t m
   . ()
  => Show a
  => MonadIOTransError FoldBlocksError t m
  => NodeConfigFile 'In
  -- ^ Path to the cardano-node config file (e.g. <path to cardano-node project>/configuration/cardano/mainnet-config.json)
  -> SocketPath
  -- ^ Path to local cardano-node socket. This is the path specified by the @--socket-path@ command line option when running the node.
  -> ValidationMode
  -> a
  -- ^ The initial accumulator state.
  -> (Env -> LedgerState -> [LedgerEvent] -> BlockInMode -> a -> IO (a, FoldStatus))
  -- ^ Accumulator function Takes:
  --
  --  * Environment (this is a constant over the whole fold).
  --  * The Ledger state (with block @i@ applied) at block @i@.
  --  * The Ledger events resulting from applying block @i@.
  --  * Block @i@.
  --  * The accumulator state at block @i - 1@.
  --
  -- And returns:
  --
  --  * The accumulator state at block @i@
  --  * A type indicating whether to stop or continue folding.
  --
  -- Note: This function can safely assume no rollback will occur even though
  -- internally this is implemented with a client protocol that may require
  -- rollback. This is achieved by only calling the accumulator on states/blocks
  -- that are older than the security parameter, k. This has the side effect of
  -- truncating the last k blocks before the node's tip.
  -> t m a
  -- ^ The final state
foldBlocks nodeConfigFilePath socketPath validationMode state0 accumulate = handleExceptions $ do
  -- NOTE this was originally implemented with a non-pipelined client then
  -- changed to a pipelined client for a modest speedup:
  --  * Non-pipelined: 1h  0m  19s
  --  * Pipelined:        46m  23s

  (env, ledgerState) <-
    modifyError FoldBlocksInitialLedgerStateError $ initialLedgerState nodeConfigFilePath

  -- Place to store the accumulated state
  -- This is a bit ugly, but easy.
  errorIORef <- liftIO $ newIORef Nothing
  stateIORef <- liftIO $ newIORef state0

  -- Derive the NetworkId as described in network-magic.md from the
  -- cardano-ledger-specs repo.
  let byronConfig =
        (\(Consensus.WrapPartialLedgerConfig (Consensus.ByronPartialLedgerConfig bc _) :* _) -> bc)
          . HFC.getPerEraLedgerConfig
          . HFC.hardForkLedgerConfigPerEra
          $ envLedgerConfig env

      networkMagic =
        NetworkMagic $
          unProtocolMagicId $
            Cardano.Chain.Genesis.gdProtocolMagicId $
              Cardano.Chain.Genesis.configGenesisData byronConfig

      networkId' = case Cardano.Chain.Genesis.configReqNetMagic byronConfig of
        RequiresNoMagic -> Mainnet
        RequiresMagic -> Testnet networkMagic

      cardanoModeParams = CardanoModeParams . EpochSlots $ 10 * envSecurityParam env

  -- Connect to the node.
  let connectInfo =
        LocalNodeConnectInfo
          { localConsensusModeParams = cardanoModeParams
          , localNodeNetworkId = networkId'
          , localNodeSocketPath = socketPath
          }

  liftIO $
    connectToLocalNode
      connectInfo
      (protocols stateIORef errorIORef env ledgerState)

  liftIO (readIORef errorIORef) >>= \case
    Just err -> throwError (FoldBlocksApplyBlockError err)
    Nothing -> liftIO $ readIORef stateIORef
 where
  protocols
    :: ()
    => IORef a
    -> IORef (Maybe LedgerStateError)
    -> Env
    -> LedgerState
    -> LocalNodeClientProtocolsInMode
  protocols stateIORef errorIORef env ledgerState =
    LocalNodeClientProtocols
      { localChainSyncClient =
          LocalChainSyncClientPipelined (chainSyncClient 50 stateIORef errorIORef env ledgerState)
      , localTxSubmissionClient = Nothing
      , localStateQueryClient = Nothing
      , localTxMonitoringClient = Nothing
      }

  -- \| Defines the client side of the chain sync protocol.
  chainSyncClient
    :: Word16
    -- \^ The maximum number of concurrent requests.
    -> IORef a
    -- \^ State accumulator. Written to on every block.
    -> IORef (Maybe LedgerStateError)
    -- \^ Resulting error if any. Written to once on protocol
    -- completion.
    -> Env
    -> LedgerState
    -> CSP.ChainSyncClientPipelined
        BlockInMode
        ChainPoint
        ChainTip
        IO
        ()
  -- \^ Client returns maybe an error.
  chainSyncClient pipelineSize stateIORef errorIORef env ledgerState0 =
    CSP.ChainSyncClientPipelined $
      pure $
        clientIdle_RequestMoreN Origin Origin Zero initialLedgerStateHistory
   where
    initialLedgerStateHistory = Seq.singleton (0, (ledgerState0, []), Origin)

    clientIdle_RequestMoreN
      :: WithOrigin BlockNo
      -> WithOrigin BlockNo
      -> Nat n -- Number of requests inflight.
      -> LedgerStateHistory
      -> CSP.ClientPipelinedStIdle n BlockInMode ChainPoint ChainTip IO ()
    clientIdle_RequestMoreN clientTip serverTip n knownLedgerStates =
      case pipelineDecisionMax pipelineSize n clientTip serverTip of
        Collect -> case n of
          Succ predN -> CSP.CollectResponse Nothing (clientNextN predN knownLedgerStates)
        _ ->
          CSP.SendMsgRequestNextPipelined
            (pure ())
            (clientIdle_RequestMoreN clientTip serverTip (Succ n) knownLedgerStates)

    clientNextN
      :: Nat n -- Number of requests inflight.
      -> LedgerStateHistory
      -> CSP.ClientStNext n BlockInMode ChainPoint ChainTip IO ()
    clientNextN n knownLedgerStates =
      CSP.ClientStNext
        { CSP.recvMsgRollForward = \blockInMode@(BlockInMode _ (Block (BlockHeader slotNo _ currBlockNo) _)) serverChainTip -> do
            let newLedgerStateE =
                  applyBlock
                    env
                    ( maybe
                        (error "Impossible! Missing Ledger state")
                        (\(_, (ledgerState, _), _) -> ledgerState)
                        (Seq.lookup 0 knownLedgerStates)
                    )
                    validationMode
                    blockInMode
            case newLedgerStateE of
              Left err -> clientIdle_DoneNwithMaybeError n (Just err)
              Right newLedgerState -> do
                let (knownLedgerStates', committedStates) = pushLedgerState env knownLedgerStates slotNo newLedgerState blockInMode
                    newClientTip = At currBlockNo
                    newServerTip = fromChainTip serverChainTip

                    ledgerStateSingleFold
                      :: (SlotNo, (LedgerState, [LedgerEvent]), WithOrigin BlockInMode) -- Ledger events for a single block
                      -> IO FoldStatus
                    ledgerStateSingleFold (_, _, Origin) = return ContinueFold
                    ledgerStateSingleFold (_, (ledgerState, ledgerEvents), At currBlock) = do
                      accumulatorState <- readIORef stateIORef
                      (newState, foldStatus) <-
                        accumulate
                          env
                          ledgerState
                          ledgerEvents
                          currBlock
                          accumulatorState
                      atomicWriteIORef stateIORef newState
                      return foldStatus

                    ledgerStateRecurser
                      :: Seq (SlotNo, LedgerStateEvents, WithOrigin BlockInMode) -- Ledger events for multiple blocks
                      -> IO FoldStatus
                    ledgerStateRecurser states = go (toList states) ContinueFold
                     where
                      go [] foldStatus = return foldStatus
                      go (s : rest) ContinueFold = do
                        newFoldStatus <- ledgerStateSingleFold s
                        go rest newFoldStatus
                      go _ StopFold = go [] StopFold
                      go _ DebugFold = go [] DebugFold

                -- NB: knownLedgerStates' is the new ledger state history i.e k blocks from the tip
                -- or also known as the mutable blocks. We default to using the mutable blocks.
                finalFoldStatus <- ledgerStateRecurser knownLedgerStates'

                case finalFoldStatus of
                  StopFold ->
                    -- We return StopFold in our accumulate function if we want to terminate the fold.
                    -- This allow us to check for a specific condition in our accumulate function
                    -- and then terminate e.g a specific stake pool was registered
                    let noError = Nothing
                     in clientIdle_DoneNwithMaybeError n noError
                  DebugFold -> do
                    currentIORefState <- readIORef stateIORef

                    -- Useful for debugging:
                    let !ioRefErr =
                          DebugError . force $
                            unlines
                              [ "newClientTip: " <> show newClientTip
                              , "newServerTip: " <> show newServerTip
                              , "newLedgerState: " <> show (snd newLedgerState)
                              , "knownLedgerStates: " <> show (extractHistory knownLedgerStates)
                              , "committedStates: " <> show (extractHistory committedStates)
                              , "numberOfRequestsInFlight: " <> show n
                              , "k: " <> show (envSecurityParam env)
                              , "Current IORef State: " <> show currentIORefState
                              ]
                    clientIdle_DoneNwithMaybeError n $ Just ioRefErr
                  ContinueFold -> return $ clientIdle_RequestMoreN newClientTip newServerTip n knownLedgerStates'
        , CSP.recvMsgRollBackward = \chainPoint serverChainTip -> do
            let newClientTip = Origin -- We don't actually keep track of blocks so we temporarily "forget" the tip.
                newServerTip = fromChainTip serverChainTip
                truncatedKnownLedgerStates = case chainPoint of
                  ChainPointAtGenesis -> initialLedgerStateHistory
                  ChainPoint slotNo _ -> rollBackLedgerStateHist knownLedgerStates slotNo
            return (clientIdle_RequestMoreN newClientTip newServerTip n truncatedKnownLedgerStates)
        }

    clientIdle_DoneNwithMaybeError
      :: Nat n -- Number of requests inflight.
      -> Maybe LedgerStateError -- Return value (maybe an error)
      -> IO (CSP.ClientPipelinedStIdle n BlockInMode ChainPoint ChainTip IO ())
    clientIdle_DoneNwithMaybeError n errorMay = case n of
      Succ predN -> return (CSP.CollectResponse Nothing (clientNext_DoneNwithMaybeError predN errorMay)) -- Ignore remaining message responses
      Zero -> do
        writeIORef errorIORef errorMay
        return (CSP.SendMsgDone ())

    clientNext_DoneNwithMaybeError
      :: Nat n -- Number of requests inflight.
      -> Maybe LedgerStateError -- Return value (maybe an error)
      -> CSP.ClientStNext n BlockInMode ChainPoint ChainTip IO ()
    clientNext_DoneNwithMaybeError n errorMay =
      CSP.ClientStNext
        { CSP.recvMsgRollForward = \_ _ -> clientIdle_DoneNwithMaybeError n errorMay
        , CSP.recvMsgRollBackward = \_ _ -> clientIdle_DoneNwithMaybeError n errorMay
        }

    fromChainTip :: ChainTip -> WithOrigin BlockNo
    fromChainTip ct = case ct of
      ChainTipAtGenesis -> Origin
      ChainTip _ _ bno -> At bno

-- | Wrap a 'ChainSyncClient' with logic that tracks the ledger state.
chainSyncClientWithLedgerState
  :: forall m a
   . Monad m
  => Env
  -> LedgerState
  -- ^ Initial ledger state
  -> ValidationMode
  -> CS.ChainSyncClient
      (BlockInMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
      ChainPoint
      ChainTip
      m
      a
  -- ^ A client to wrap. The block is annotated with a 'Either LedgerStateError
  -- LedgerState'. This is either an error from validating a block or
  -- the current 'LedgerState' from applying the current block. If we
  -- trust the node, then we generally expect blocks to validate. Also note that
  -- after a block fails to validate we may still roll back to a validated
  -- block, in which case the valid 'LedgerState' will be passed here again.
  -> CS.ChainSyncClient
      BlockInMode
      ChainPoint
      ChainTip
      m
      a
  -- ^ A client that acts just like the wrapped client but doesn't require the
  -- 'LedgerState' annotation on the block type.
chainSyncClientWithLedgerState env ledgerState0 validationMode (CS.ChainSyncClient clientTop) =
  CS.ChainSyncClient (goClientStIdle (Right initialLedgerStateHistory) <$> clientTop)
 where
  goClientStIdle
    :: Either LedgerStateError (History (Either LedgerStateError LedgerStateEvents))
    -> CS.ClientStIdle
        (BlockInMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
        ChainPoint
        ChainTip
        m
        a
    -> CS.ClientStIdle
        BlockInMode
        ChainPoint
        ChainTip
        m
        a
  goClientStIdle history client = case client of
    CS.SendMsgRequestNext a b -> CS.SendMsgRequestNext a (goClientStNext history b)
    CS.SendMsgFindIntersect ps a -> CS.SendMsgFindIntersect ps (goClientStIntersect history a)
    CS.SendMsgDone a -> CS.SendMsgDone a

  -- This is where the magic happens. We intercept the blocks and rollbacks
  -- and use it to maintain the correct ledger state.
  goClientStNext
    :: Either LedgerStateError (History (Either LedgerStateError LedgerStateEvents))
    -> CS.ClientStNext
        (BlockInMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
        ChainPoint
        ChainTip
        m
        a
    -> CS.ClientStNext
        BlockInMode
        ChainPoint
        ChainTip
        m
        a
  goClientStNext (Left err) (CS.ClientStNext recvMsgRollForward recvMsgRollBackward) =
    CS.ClientStNext
      ( \blkInMode tip ->
          CS.ChainSyncClient $
            goClientStIdle (Left err)
              <$> CS.runChainSyncClient
                (recvMsgRollForward (blkInMode, Left err) tip)
      )
      ( \point tip ->
          CS.ChainSyncClient $
            goClientStIdle (Left err) <$> CS.runChainSyncClient (recvMsgRollBackward point tip)
      )
  goClientStNext (Right history) (CS.ClientStNext recvMsgRollForward recvMsgRollBackward) =
    CS.ClientStNext
      ( \blkInMode@(BlockInMode _ (Block (BlockHeader slotNo _ _) _)) tip ->
          CS.ChainSyncClient $
            let
              newLedgerStateE = case Seq.lookup 0 history of
                Nothing -> error "Impossible! History should always be non-empty"
                Just (_, Left err, _) -> Left err
                Just (_, Right (oldLedgerState, _), _) ->
                  applyBlock
                    env
                    oldLedgerState
                    validationMode
                    blkInMode
              (history', _) = pushLedgerState env history slotNo newLedgerStateE blkInMode
             in
              goClientStIdle (Right history')
                <$> CS.runChainSyncClient
                  (recvMsgRollForward (blkInMode, newLedgerStateE) tip)
      )
      ( \point tip ->
          let
            oldestSlot = case history of
              _ Seq.:|> (s, _, _) -> s
              Seq.Empty -> error "Impossible! History should always be non-empty"
            history' = ( \h ->
                          if Seq.null h
                            then Left (InvalidRollback oldestSlot point)
                            else Right h
                       )
              $ case point of
                ChainPointAtGenesis -> initialLedgerStateHistory
                ChainPoint slotNo _ -> rollBackLedgerStateHist history slotNo
           in
            CS.ChainSyncClient $
              goClientStIdle history' <$> CS.runChainSyncClient (recvMsgRollBackward point tip)
      )

  goClientStIntersect
    :: Either LedgerStateError (History (Either LedgerStateError LedgerStateEvents))
    -> CS.ClientStIntersect
        (BlockInMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
        ChainPoint
        ChainTip
        m
        a
    -> CS.ClientStIntersect
        BlockInMode
        ChainPoint
        ChainTip
        m
        a
  goClientStIntersect history (CS.ClientStIntersect recvMsgIntersectFound recvMsgIntersectNotFound) =
    CS.ClientStIntersect
      ( \point tip ->
          CS.ChainSyncClient
            (goClientStIdle history <$> CS.runChainSyncClient (recvMsgIntersectFound point tip))
      )
      ( \tip ->
          CS.ChainSyncClient (goClientStIdle history <$> CS.runChainSyncClient (recvMsgIntersectNotFound tip))
      )

  initialLedgerStateHistory :: History (Either LedgerStateError LedgerStateEvents)
  initialLedgerStateHistory = Seq.singleton (0, Right (ledgerState0, []), Origin)

-- | See 'chainSyncClientWithLedgerState'.
chainSyncClientPipelinedWithLedgerState
  :: forall m a
   . Monad m
  => Env
  -> LedgerState
  -> ValidationMode
  -> CSP.ChainSyncClientPipelined
      (BlockInMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
      ChainPoint
      ChainTip
      m
      a
  -> CSP.ChainSyncClientPipelined
      BlockInMode
      ChainPoint
      ChainTip
      m
      a
chainSyncClientPipelinedWithLedgerState env ledgerState0 validationMode (CSP.ChainSyncClientPipelined clientTop) =
  CSP.ChainSyncClientPipelined
    (goClientPipelinedStIdle (Right initialLedgerStateHistory) Zero <$> clientTop)
 where
  goClientPipelinedStIdle
    :: Either LedgerStateError (History (Either LedgerStateError LedgerStateEvents))
    -> Nat n
    -> CSP.ClientPipelinedStIdle
        n
        (BlockInMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
        ChainPoint
        ChainTip
        m
        a
    -> CSP.ClientPipelinedStIdle
        n
        BlockInMode
        ChainPoint
        ChainTip
        m
        a
  goClientPipelinedStIdle history n client = case client of
    CSP.SendMsgRequestNext a b -> CSP.SendMsgRequestNext a (goClientStNext history n b)
    CSP.SendMsgRequestNextPipelined m a -> CSP.SendMsgRequestNextPipelined m (goClientPipelinedStIdle history (Succ n) a)
    CSP.SendMsgFindIntersect ps a -> CSP.SendMsgFindIntersect ps (goClientPipelinedStIntersect history n a)
    CSP.CollectResponse a b -> case n of
      Succ nPrev ->
        CSP.CollectResponse
          ((fmap . fmap) (goClientPipelinedStIdle history n) a)
          (goClientStNext history nPrev b)
    CSP.SendMsgDone a -> CSP.SendMsgDone a

  -- This is where the magic happens. We intercept the blocks and rollbacks
  -- and use it to maintain the correct ledger state.
  goClientStNext
    :: Either LedgerStateError (History (Either LedgerStateError LedgerStateEvents))
    -> Nat n
    -> CSP.ClientStNext
        n
        (BlockInMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
        ChainPoint
        ChainTip
        m
        a
    -> CSP.ClientStNext
        n
        BlockInMode
        ChainPoint
        ChainTip
        m
        a
  goClientStNext (Left err) n (CSP.ClientStNext recvMsgRollForward recvMsgRollBackward) =
    CSP.ClientStNext
      ( \blkInMode tip ->
          goClientPipelinedStIdle (Left err) n
            <$> recvMsgRollForward
              (blkInMode, Left err)
              tip
      )
      ( \point tip ->
          goClientPipelinedStIdle (Left err) n <$> recvMsgRollBackward point tip
      )
  goClientStNext (Right history) n (CSP.ClientStNext recvMsgRollForward recvMsgRollBackward) =
    CSP.ClientStNext
      ( \blkInMode@(BlockInMode _ (Block (BlockHeader slotNo _ _) _)) tip ->
          let
            newLedgerStateE = case Seq.lookup 0 history of
              Nothing -> error "Impossible! History should always be non-empty"
              Just (_, Left err, _) -> Left err
              Just (_, Right (oldLedgerState, _), _) ->
                applyBlock
                  env
                  oldLedgerState
                  validationMode
                  blkInMode
            (history', _) = pushLedgerState env history slotNo newLedgerStateE blkInMode
           in
            goClientPipelinedStIdle (Right history') n
              <$> recvMsgRollForward
                (blkInMode, newLedgerStateE)
                tip
      )
      ( \point tip ->
          let
            oldestSlot = case history of
              _ Seq.:|> (s, _, _) -> s
              Seq.Empty -> error "Impossible! History should always be non-empty"
            history' = ( \h ->
                          if Seq.null h
                            then Left (InvalidRollback oldestSlot point)
                            else Right h
                       )
              $ case point of
                ChainPointAtGenesis -> initialLedgerStateHistory
                ChainPoint slotNo _ -> rollBackLedgerStateHist history slotNo
           in
            goClientPipelinedStIdle history' n <$> recvMsgRollBackward point tip
      )

  goClientPipelinedStIntersect
    :: Either LedgerStateError (History (Either LedgerStateError LedgerStateEvents))
    -> Nat n
    -> CSP.ClientPipelinedStIntersect
        (BlockInMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
        ChainPoint
        ChainTip
        m
        a
    -> CSP.ClientPipelinedStIntersect
        BlockInMode
        ChainPoint
        ChainTip
        m
        a
  goClientPipelinedStIntersect history _ (CSP.ClientPipelinedStIntersect recvMsgIntersectFound recvMsgIntersectNotFound) =
    CSP.ClientPipelinedStIntersect
      (\point tip -> goClientPipelinedStIdle history Zero <$> recvMsgIntersectFound point tip)
      (\tip -> goClientPipelinedStIdle history Zero <$> recvMsgIntersectNotFound tip)

  initialLedgerStateHistory :: History (Either LedgerStateError LedgerStateEvents)
  initialLedgerStateHistory = Seq.singleton (0, Right (ledgerState0, []), Origin)

extractHistory
  :: History LedgerStateEvents
  -> [(SlotNo, [LedgerEvent], BlockNo)]
extractHistory historySeq =
  let histList = toList historySeq
   in List.map
        (\(slotNo, (_ledgerState, ledgerEvents), block) -> (slotNo, ledgerEvents, getBlockNo block))
        histList

getBlockNo :: WithOrigin BlockInMode -> BlockNo
getBlockNo = Consensus.withOrigin (BlockNo 0) (blockNo . toConsensusBlock)

{- HLINT ignore chainSyncClientPipelinedWithLedgerState "Use fmap" -}

-- | A history of k (security parameter) recent ledger states. The head is the
-- most recent item. Elements are:
--
-- * Slot number that a new block occurred
-- * The ledger state and events after applying the new block
-- * The new block
type LedgerStateHistory = History LedgerStateEvents

type History a = Seq (SlotNo, a, WithOrigin BlockInMode)

-- | Add a new ledger state to the history
pushLedgerState
  :: Env
  -- ^ Environment used to get the security param, k.
  -> History a
  -- ^ History of k items.
  -> SlotNo
  -- ^ Slot number of the new item.
  -> a
  -- ^ New item to add to the history
  -> BlockInMode
  -- ^ The block that (when applied to the previous
  -- item) resulted in the new item.
  -> (History a, History a)
  -- ^ ( The new history with the new item appended
  --   , Any existing items that are now past the security parameter
  --      and hence can no longer be rolled back.
  --   )
pushLedgerState env hist sn st block =
  Seq.splitAt
    (fromIntegral $ envSecurityParam env + 1)
    ((sn, st, At block) Seq.:<| hist)

rollBackLedgerStateHist :: History a -> SlotNo -> History a
rollBackLedgerStateHist hist maxInc = Seq.dropWhileL ((> maxInc) . (\(x, _, _) -> x)) hist

--------------------------------------------------------------------------------
-- Everything below was copied/adapted from db-sync                           --
--------------------------------------------------------------------------------

genesisConfigToEnv
  :: GenesisConfig
  -> Either GenesisConfigError Env
genesisConfigToEnv
  -- enp
  genCfg =
    case genCfg of
      GenesisCardano _ bCfg _ transCfg
        | Cardano.Crypto.ProtocolMagic.unProtocolMagicId (Cardano.Chain.Genesis.configProtocolMagicId bCfg)
            /= Ledger.sgNetworkMagic shelleyGenesis ->
            Left . NECardanoConfig $
              mconcat
                [ "ProtocolMagicId "
                , textShow
                    (Cardano.Crypto.ProtocolMagic.unProtocolMagicId $ Cardano.Chain.Genesis.configProtocolMagicId bCfg)
                , " /= "
                , textShow (Ledger.sgNetworkMagic shelleyGenesis)
                ]
        | Cardano.Chain.Genesis.gdStartTime (Cardano.Chain.Genesis.configGenesisData bCfg)
            /= Ledger.sgSystemStart shelleyGenesis ->
            Left . NECardanoConfig $
              mconcat
                [ "SystemStart "
                , textShow (Cardano.Chain.Genesis.gdStartTime $ Cardano.Chain.Genesis.configGenesisData bCfg)
                , " /= "
                , textShow (Ledger.sgSystemStart shelleyGenesis)
                ]
        | otherwise ->
            let
              topLevelConfig = Consensus.pInfoConfig $ fst $ mkProtocolInfoCardano genCfg
             in
              Right $
                Env
                  { envLedgerConfig = Consensus.topLevelConfigLedger topLevelConfig
                  , envConsensusConfig = Consensus.topLevelConfigProtocol topLevelConfig
                  }
       where
        shelleyGenesis = transCfg ^. Ledger.tcShelleyGenesisL

readNodeConfig
  :: MonadError Text m
  => MonadIO m
  => NodeConfigFile 'In
  -> m NodeConfig
readNodeConfig (File ncf) = do
  ncfg <- liftEither . parseNodeConfig =<< readByteString ncf "node"
  return
    ncfg
      { ncByronGenesisFile =
          mapFile (mkAdjustPath ncf) (ncByronGenesisFile ncfg)
      , ncShelleyGenesisFile =
          mapFile (mkAdjustPath ncf) (ncShelleyGenesisFile ncfg)
      , ncAlonzoGenesisFile =
          mapFile (mkAdjustPath ncf) (ncAlonzoGenesisFile ncfg)
      , ncConwayGenesisFile =
          mapFile (mkAdjustPath ncf) <$> ncConwayGenesisFile ncfg
      }

data NodeConfig = NodeConfig
  { ncPBftSignatureThreshold :: !(Maybe Double)
  , ncByronGenesisFile :: !(File ByronGenesisConfig 'In)
  , ncByronGenesisHash :: !GenesisHashByron
  , ncShelleyGenesisFile :: !(File ShelleyGenesisConfig 'In)
  , ncShelleyGenesisHash :: !GenesisHashShelley
  , ncAlonzoGenesisFile :: !(File AlonzoGenesis 'In)
  , ncAlonzoGenesisHash :: !GenesisHashAlonzo
  , ncConwayGenesisFile :: !(Maybe (File ConwayGenesisConfig 'In))
  , ncConwayGenesisHash :: !(Maybe GenesisHashConway)
  , ncRequiresNetworkMagic :: !Cardano.Crypto.RequiresNetworkMagic
  , ncByronProtocolVersion :: !Cardano.Chain.Update.ProtocolVersion
  , ncHardForkTriggers :: !Consensus.CardanoHardForkTriggers
  }

instance FromJSON NodeConfig where
  parseJSON =
    Aeson.withObject "NodeConfig" parse
   where
    parse :: Object -> Parser NodeConfig
    parse o =
      NodeConfig
        <$> o .:? "PBftSignatureThreshold"
        <*> fmap File (o .: "ByronGenesisFile")
        <*> fmap GenesisHashByron (o .: "ByronGenesisHash")
        <*> fmap File (o .: "ShelleyGenesisFile")
        <*> fmap GenesisHashShelley (o .: "ShelleyGenesisHash")
        <*> fmap File (o .: "AlonzoGenesisFile")
        <*> fmap GenesisHashAlonzo (o .: "AlonzoGenesisHash")
        <*> (fmap . fmap) File (o .:? "ConwayGenesisFile")
        <*> (fmap . fmap) GenesisHashConway (o .:? "ConwayGenesisHash")
        <*> o .: "RequiresNetworkMagic"
        <*> parseByronProtocolVersion o
        <*> parseHardForkTriggers o

    parseByronProtocolVersion :: Object -> Parser Cardano.Chain.Update.ProtocolVersion
    parseByronProtocolVersion o =
      Cardano.Chain.Update.ProtocolVersion
        <$> o .: "LastKnownBlockVersion-Major"
        <*> o .: "LastKnownBlockVersion-Minor"
        <*> o .: "LastKnownBlockVersion-Alt"

    parseHardForkTriggers :: Object -> Parser Consensus.CardanoHardForkTriggers
    parseHardForkTriggers o =
      Consensus.CardanoHardForkTriggers'
        <$> parseShelleyHardForkEpoch o
        <*> parseAllegraHardForkEpoch o
        <*> parseMaryHardForkEpoch o
        <*> parseAlonzoHardForkEpoch o
        <*> parseBabbageHardForkEpoch o
        <*> parseConwayHardForkEpoch o

    parseShelleyHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
    parseShelleyHardForkEpoch o =
      asum
        [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestShelleyHardForkAtEpoch"
        , pure $ Consensus.TriggerHardForkAtVersion 2 -- Mainnet default
        ]

    parseAllegraHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
    parseAllegraHardForkEpoch o =
      asum
        [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestAllegraHardForkAtEpoch"
        , pure $ Consensus.TriggerHardForkAtVersion 3 -- Mainnet default
        ]

    parseMaryHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
    parseMaryHardForkEpoch o =
      asum
        [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestMaryHardForkAtEpoch"
        , pure $ Consensus.TriggerHardForkAtVersion 4 -- Mainnet default
        ]

    parseAlonzoHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
    parseAlonzoHardForkEpoch o =
      asum
        [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestAlonzoHardForkAtEpoch"
        , pure $ Consensus.TriggerHardForkAtVersion 5 -- Mainnet default
        ]
    parseBabbageHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
    parseBabbageHardForkEpoch o =
      asum
        [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestBabbageHardForkAtEpoch"
        , pure $ Consensus.TriggerHardForkAtVersion 7 -- Mainnet default
        ]

    parseConwayHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
    parseConwayHardForkEpoch o =
      asum
        [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestConwayHardForkAtEpoch"
        , pure $ Consensus.TriggerHardForkAtVersion 9 -- Mainnet default
        ]

----------------------------------------------------------------------
-- WARNING When adding new entries above, be aware that if there is an
-- intra-era fork, then the numbering is not consecutive.
----------------------------------------------------------------------

parseNodeConfig :: ByteString -> Either Text NodeConfig
parseNodeConfig bs =
  case Yaml.decodeEither' bs of
    Left err -> Left $ "Error parsing node config: " <> textShow err
    Right nc -> Right nc

mkAdjustPath :: FilePath -> (FilePath -> FilePath)
mkAdjustPath nodeConfigFilePath fp = takeDirectory nodeConfigFilePath </> fp

readByteString
  :: MonadError Text m
  => MonadIO m
  => FilePath
  -> Text
  -> m ByteString
readByteString fp cfgType = (liftEither <=< liftIO) $
  catch (Right <$> BS.readFile fp) $ \(_ :: IOException) ->
    return $
      Left $
        mconcat
          ["Cannot read the ", cfgType, " configuration file at : ", Text.pack fp]

initLedgerStateVar :: GenesisConfig -> LedgerState
initLedgerStateVar genesisConfig =
  LedgerState
    { clsState = Ledger.ledgerState $ Consensus.pInfoInitLedger $ fst protocolInfo
    }
 where
  protocolInfo = mkProtocolInfoCardano genesisConfig

newtype LedgerState = LedgerState
  { clsState :: Consensus.CardanoLedgerState Consensus.StandardCrypto
  }
  deriving Show

-- | Retrieve new epoch state from the ledger state, or an error on failure
getAnyNewEpochState
  :: ShelleyBasedEra era
  -> LedgerState
  -> Either LedgerStateError AnyNewEpochState
getAnyNewEpochState sbe (LedgerState ls) =
  AnyNewEpochState sbe <$> getNewEpochState sbe ls

getNewEpochState
  :: ShelleyBasedEra era
  -> Consensus.CardanoLedgerState Consensus.StandardCrypto
  -> Either LedgerStateError (ShelleyAPI.NewEpochState (ShelleyLedgerEra era))
getNewEpochState era x = do
  let err = UnexpectedLedgerState (shelleyBasedEraConstraints era $ AnyShelleyBasedEra era) x
  case era of
    ShelleyBasedEraShelley ->
      case x of
        Consensus.LedgerStateShelley current ->
          pure $ Shelley.shelleyLedgerState current
        _ -> Left err
    ShelleyBasedEraAllegra ->
      case x of
        Consensus.LedgerStateAllegra current ->
          pure $ Shelley.shelleyLedgerState current
        _ -> Left err
    ShelleyBasedEraMary ->
      case x of
        Consensus.LedgerStateMary current ->
          pure $ Shelley.shelleyLedgerState current
        _ -> Left err
    ShelleyBasedEraAlonzo ->
      case x of
        Consensus.LedgerStateAlonzo current ->
          pure $ Shelley.shelleyLedgerState current
        _ -> Left err
    ShelleyBasedEraBabbage ->
      case x of
        Consensus.LedgerStateBabbage current ->
          pure $ Shelley.shelleyLedgerState current
        _ -> Left err
    ShelleyBasedEraConway ->
      case x of
        Consensus.LedgerStateConway current ->
          pure $ Shelley.shelleyLedgerState current
        _ -> Left err

encodeLedgerState
  :: Consensus.CardanoCodecConfig Consensus.StandardCrypto
  -> LedgerState
  -> CBOR.Encoding
encodeLedgerState ccfg (LedgerState st) =
  encodeDisk @(Consensus.CardanoBlock Consensus.StandardCrypto) ccfg st

decodeLedgerState
  :: Consensus.CardanoCodecConfig Consensus.StandardCrypto
  -> forall s
   . CBOR.Decoder s LedgerState
decodeLedgerState ccfg =
  LedgerState <$> decodeDisk @(Consensus.CardanoBlock Consensus.StandardCrypto) ccfg

type LedgerStateEvents = (LedgerState, [LedgerEvent])

toLedgerStateEvents
  :: Ledger.LedgerResult
      (Consensus.CardanoLedgerState Consensus.StandardCrypto)
      (Consensus.CardanoLedgerState Consensus.StandardCrypto)
  -> LedgerStateEvents
toLedgerStateEvents lr = (ledgerState, ledgerEvents)
 where
  ledgerState = LedgerState (Ledger.lrResult lr)
  ledgerEvents =
    mapMaybe
      ( toLedgerEvent
          . WrapLedgerEvent @(Consensus.CardanoBlock Consensus.StandardCrypto)
      )
      $ Ledger.lrEvents lr

-- Usually only one constructor, but may have two when we are preparing for a HFC event.
data GenesisConfig
  = GenesisCardano
      !NodeConfig
      !Cardano.Chain.Genesis.Config
      !GenesisHashShelley
      !(Ledger.TransitionConfig (Ledger.LatestKnownEra Consensus.StandardCrypto))

newtype LedgerStateDir = LedgerStateDir
  { unLedgerStateDir :: FilePath
  }
  deriving Show

newtype NetworkName = NetworkName
  { unNetworkName :: Text
  }
  deriving Show

type NodeConfigFile = File NodeConfig

mkProtocolInfoCardano
  :: GenesisConfig
  -> ( Consensus.ProtocolInfo
        (Consensus.CardanoBlock Consensus.StandardCrypto)
     , IO [BlockForging IO (Consensus.CardanoBlock Consensus.StandardCrypto)]
     )
mkProtocolInfoCardano (GenesisCardano dnc byronGenesis shelleyGenesisHash transCfg) =
  Consensus.protocolInfoCardano
    Consensus.CardanoProtocolParams
      { Consensus.paramsByron =
          Consensus.ProtocolParamsByron
            { Consensus.byronGenesis = byronGenesis
            , Consensus.byronPbftSignatureThreshold =
                Consensus.PBftSignatureThreshold <$> ncPBftSignatureThreshold dnc
            , Consensus.byronProtocolVersion = ncByronProtocolVersion dnc
            , Consensus.byronSoftwareVersion = Byron.softwareVersion
            , Consensus.byronLeaderCredentials = Nothing
            , Consensus.byronMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsShelleyBased =
          Consensus.ProtocolParamsShelleyBased
            { Consensus.shelleyBasedInitialNonce = shelleyPraosNonce shelleyGenesisHash
            , Consensus.shelleyBasedLeaderCredentials = []
            }
      , Consensus.paramsShelley =
          Consensus.ProtocolParamsShelley
            { Consensus.shelleyProtVer = ProtVer (natVersion @3) 0
            , Consensus.shelleyMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsAllegra =
          Consensus.ProtocolParamsAllegra
            { Consensus.allegraProtVer = ProtVer (natVersion @4) 0
            , Consensus.allegraMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsMary =
          Consensus.ProtocolParamsMary
            { Consensus.maryProtVer = ProtVer (natVersion @5) 0
            , Consensus.maryMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsAlonzo =
          Consensus.ProtocolParamsAlonzo
            { Consensus.alonzoProtVer = ProtVer (natVersion @7) 0
            , Consensus.alonzoMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsBabbage =
          Consensus.ProtocolParamsBabbage
            { Consensus.babbageProtVer = ProtVer (natVersion @9) 0
            , Consensus.babbageMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsConway =
          Consensus.ProtocolParamsConway
            { Consensus.conwayProtVer = ProtVer (natVersion @10) 0
            , Consensus.conwayMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.hardForkTriggers = ncHardForkTriggers dnc
      , Consensus.ledgerTransitionConfig = transCfg
      , -- NOTE: this can become a parameter once https://github.com/IntersectMBO/cardano-node/issues/5730 is implemented.
        Consensus.checkpoints = Consensus.emptyCheckpointsMap
      }

-- | Compute the Nonce from the hash of the Genesis file.
shelleyPraosNonce :: GenesisHashShelley -> Ledger.Nonce
shelleyPraosNonce genesisHash =
  Ledger.Nonce (Cardano.Crypto.Hash.Class.castHash $ unGenesisHashShelley genesisHash)

readCardanoGenesisConfig
  :: MonadIOTransError GenesisConfigError t m
  => Maybe (CardanoEra era)
  -- ^ Provide era witness to read Alonzo Genesis in an era-sensitive manner (see
  -- 'Cardano.Api.Genesis.decodeAlonzGenesis' for more details)
  -> NodeConfig
  -> t m GenesisConfig
readCardanoGenesisConfig mEra enc = do
  byronGenesis <- readByronGenesisConfig enc
  ShelleyConfig shelleyGenesis shelleyGenesisHash <- readShelleyGenesisConfig enc
  alonzoGenesis <- readAlonzoGenesisConfig mEra enc
  conwayGenesis <- readConwayGenesisConfig enc
  let transCfg = Ledger.mkLatestTransitionConfig shelleyGenesis alonzoGenesis conwayGenesis
  pure $ GenesisCardano enc byronGenesis shelleyGenesisHash transCfg

data GenesisConfigError
  = NEError !Text
  | NEByronConfig !FilePath !Cardano.Chain.Genesis.ConfigurationError
  | NEShelleyConfig !FilePath !Text
  | NEAlonzoConfig !FilePath !Text
  | NEConwayConfig !FilePath !Text
  | NECardanoConfig !Text
  deriving Show

instance Exception GenesisConfigError

instance Error GenesisConfigError where
  prettyError = \case
    NEError t -> "Error:" <+> pretty t
    NEByronConfig fp ce ->
      mconcat
        [ "Failed reading Byron genesis file "
        , pretty fp
        , ": "
        , pshow ce
        ]
    NEShelleyConfig fp txt ->
      mconcat
        [ "Failed reading Shelley genesis file "
        , pretty fp
        , ": "
        , pretty txt
        ]
    NEAlonzoConfig fp txt ->
      mconcat
        [ "Failed reading Alonzo genesis file "
        , pretty fp
        , ": "
        , pretty txt
        ]
    NEConwayConfig fp txt ->
      mconcat
        [ "Failed reading Conway genesis file "
        , pretty fp
        , ": "
        , pretty txt
        ]
    NECardanoConfig err ->
      mconcat
        [ "With Cardano protocol, Byron/Shelley config mismatch:\n"
        , "   "
        , pretty err
        ]

readByronGenesisConfig
  :: MonadIOTransError GenesisConfigError t m
  => NodeConfig
  -> t m Cardano.Chain.Genesis.Config
readByronGenesisConfig enc = do
  let file = unFile $ ncByronGenesisFile enc
  genHash <-
    liftEither
      . first NEError
      $ Cardano.Crypto.Hashing.decodeAbstractHash (unGenesisHashByron $ ncByronGenesisHash enc)
  modifyError (NEByronConfig file) $
    Cardano.Chain.Genesis.mkConfigFromFile (ncRequiresNetworkMagic enc) file genHash

readShelleyGenesisConfig
  :: MonadIOTransError GenesisConfigError t m
  => NodeConfig
  -> t m ShelleyConfig
readShelleyGenesisConfig enc = do
  let file = ncShelleyGenesisFile enc
  modifyError (NEShelleyConfig (unFile file) . renderShelleyGenesisError) $
    readShelleyGenesis file (ncShelleyGenesisHash enc)

readAlonzoGenesisConfig
  :: MonadIOTransError GenesisConfigError t m
  => Maybe (CardanoEra era)
  -- ^ Provide era witness to read Alonzo Genesis in an era-sensitive manner (see
  -- 'Cardano.Api.Genesis.decodeAlonzGenesis' for more details)
  -> NodeConfig
  -> t m AlonzoGenesis
readAlonzoGenesisConfig mEra enc = do
  let file = ncAlonzoGenesisFile enc
  modifyError (NEAlonzoConfig (unFile file) . renderAlonzoGenesisError) $
    readAlonzoGenesis mEra file (ncAlonzoGenesisHash enc)

-- | If the conway genesis file does not exist we simply put in a default.
readConwayGenesisConfig
  :: MonadIOTransError GenesisConfigError t m
  => NodeConfig
  -> t m (ConwayGenesis Consensus.StandardCrypto)
readConwayGenesisConfig enc = do
  let mFile = ncConwayGenesisFile enc
  case mFile of
    Nothing -> return conwayGenesisDefaults
    Just fp ->
      modifyError (NEConwayConfig (unFile fp) . renderConwayGenesisError) $
        readConwayGenesis (ncConwayGenesisFile enc) (ncConwayGenesisHash enc)

readShelleyGenesis
  :: forall m t
   . MonadIOTransError ShelleyGenesisError t m
  => ShelleyGenesisFile 'In
  -> GenesisHashShelley
  -> t m ShelleyConfig
readShelleyGenesis (File file) expectedGenesisHash = do
  content <-
    modifyError id $ handleIOExceptT (ShelleyGenesisReadError file . textShow) $ BS.readFile file
  let genesisHash = GenesisHashShelley (Cardano.Crypto.Hash.Class.hashWith id content)
  checkExpectedGenesisHash genesisHash
  genesis <-
    liftEither
      . first (ShelleyGenesisDecodeError file . Text.pack)
      $ Aeson.eitherDecodeStrict' content
  pure $ ShelleyConfig genesis genesisHash
 where
  checkExpectedGenesisHash :: GenesisHashShelley -> t m ()
  checkExpectedGenesisHash actual =
    when (actual /= expectedGenesisHash) $
      throwError (ShelleyGenesisHashMismatch actual expectedGenesisHash)

data ShelleyGenesisError
  = ShelleyGenesisReadError !FilePath !Text
  | ShelleyGenesisHashMismatch !GenesisHashShelley !GenesisHashShelley -- actual, expected
  | ShelleyGenesisDecodeError !FilePath !Text
  deriving Show

instance Exception ShelleyGenesisError

renderShelleyGenesisError :: ShelleyGenesisError -> Text
renderShelleyGenesisError sge =
  case sge of
    ShelleyGenesisReadError fp err ->
      mconcat
        [ "There was an error reading the genesis file: "
        , Text.pack fp
        , " Error: "
        , err
        ]
    ShelleyGenesisHashMismatch actual expected ->
      mconcat
        [ "Wrong Shelley genesis file: the actual hash is "
        , renderHash (unGenesisHashShelley actual)
        , ", but the expected Shelley genesis hash given in the node "
        , "configuration file is "
        , renderHash (unGenesisHashShelley expected)
        , "."
        ]
    ShelleyGenesisDecodeError fp err ->
      mconcat
        [ "There was an error parsing the genesis file: "
        , Text.pack fp
        , " Error: "
        , err
        ]

readAlonzoGenesis
  :: forall m t era
   . MonadIOTransError AlonzoGenesisError t m
  => Maybe (CardanoEra era)
  -- ^ Provide era witness to read Alonzo Genesis in an era-sensitive manner (see
  -- 'Cardano.Api.Genesis.decodeAlonzGenesis' for more details)
  -> File AlonzoGenesis 'In
  -> GenesisHashAlonzo
  -> t m AlonzoGenesis
readAlonzoGenesis mEra (File file) expectedGenesisHash = do
  content <-
    modifyError id $ handleIOExceptT (AlonzoGenesisReadError file . textShow) $ LBS.readFile file
  let genesisHash = GenesisHashAlonzo . Cardano.Crypto.Hash.Class.hashWith id $ LBS.toStrict content
  checkExpectedGenesisHash genesisHash
  modifyError (AlonzoGenesisDecodeError file . Text.pack) $
    decodeAlonzoGenesis mEra content
 where
  checkExpectedGenesisHash :: GenesisHashAlonzo -> t m ()
  checkExpectedGenesisHash actual =
    when (actual /= expectedGenesisHash) $
      throwError (AlonzoGenesisHashMismatch actual expectedGenesisHash)

data AlonzoGenesisError
  = AlonzoGenesisReadError !FilePath !Text
  | AlonzoGenesisHashMismatch !GenesisHashAlonzo !GenesisHashAlonzo -- actual, expected
  | AlonzoGenesisDecodeError !FilePath !Text
  deriving Show

instance Exception AlonzoGenesisError

renderAlonzoGenesisError :: AlonzoGenesisError -> Text
renderAlonzoGenesisError sge =
  case sge of
    AlonzoGenesisReadError fp err ->
      mconcat
        [ "There was an error reading the genesis file: "
        , Text.pack fp
        , " Error: "
        , err
        ]
    AlonzoGenesisHashMismatch actual expected ->
      mconcat
        [ "Wrong Alonzo genesis file: the actual hash is "
        , renderHash (unGenesisHashAlonzo actual)
        , ", but the expected Alonzo genesis hash given in the node "
        , "configuration file is "
        , renderHash (unGenesisHashAlonzo expected)
        , "."
        ]
    AlonzoGenesisDecodeError fp err ->
      mconcat
        [ "There was an error parsing the genesis file: "
        , Text.pack fp
        , " Error: "
        , err
        ]

readConwayGenesis
  :: forall m t
   . MonadIOTransError ConwayGenesisError t m
  => Maybe (ConwayGenesisFile 'In)
  -> Maybe GenesisHashConway
  -> t m (ConwayGenesis Consensus.StandardCrypto)
readConwayGenesis Nothing Nothing = return conwayGenesisDefaults
readConwayGenesis (Just fp) Nothing = throwError $ ConwayGenesisHashMissing $ unFile fp
readConwayGenesis Nothing (Just _) = throwError ConwayGenesisFileMissing
readConwayGenesis (Just (File file)) (Just expectedGenesisHash) = do
  content <-
    modifyError id $ handleIOExceptT (ConwayGenesisReadError file . textShow) $ BS.readFile file
  let genesisHash = GenesisHashConway (Cardano.Crypto.Hash.Class.hashWith id content)
  checkExpectedGenesisHash genesisHash
  liftEither . first (ConwayGenesisDecodeError file . Text.pack) $ Aeson.eitherDecodeStrict' content
 where
  checkExpectedGenesisHash :: GenesisHashConway -> t m ()
  checkExpectedGenesisHash actual =
    when (actual /= expectedGenesisHash) $
      throwError (ConwayGenesisHashMismatch actual expectedGenesisHash)

data ConwayGenesisError
  = ConwayGenesisReadError !FilePath !Text
  | ConwayGenesisHashMismatch !GenesisHashConway !GenesisHashConway -- actual, expected
  | ConwayGenesisHashMissing !FilePath
  | ConwayGenesisFileMissing
  | ConwayGenesisDecodeError !FilePath !Text
  deriving Show

instance Exception ConwayGenesisError

renderConwayGenesisError :: ConwayGenesisError -> Text
renderConwayGenesisError sge =
  case sge of
    ConwayGenesisFileMissing ->
      mconcat
        [ "\"ConwayGenesisFile\" is missing from node configuration. "
        ]
    ConwayGenesisHashMissing fp ->
      mconcat
        [ "\"ConwayGenesisHash\" is missing from node configuration: "
        , Text.pack fp
        ]
    ConwayGenesisReadError fp err ->
      mconcat
        [ "There was an error reading the genesis file: "
        , Text.pack fp
        , " Error: "
        , err
        ]
    ConwayGenesisHashMismatch actual expected ->
      mconcat
        [ "Wrong Conway genesis file: the actual hash is "
        , renderHash (unGenesisHashConway actual)
        , ", but the expected Conway genesis hash given in the node "
        , "configuration file is "
        , renderHash (unGenesisHashConway expected)
        , "."
        ]
    ConwayGenesisDecodeError fp err ->
      mconcat
        [ "There was an error parsing the genesis file: "
        , Text.pack fp
        , " Error: "
        , err
        ]

renderHash
  :: Cardano.Crypto.Hash.Class.Hash Cardano.Crypto.Hash.Blake2b.Blake2b_256 ByteString -> Text
renderHash h = Text.decodeUtf8 $ Base16.encode (Cardano.Crypto.Hash.Class.hashToBytes h)

newtype StakeCred = StakeCred {_unStakeCred :: Ledger.Credential 'Ledger.Staking Consensus.StandardCrypto}
  deriving (Eq, Ord)

data Env = Env
  { envLedgerConfig :: Consensus.CardanoLedgerConfig Consensus.StandardCrypto
  , envConsensusConfig :: Consensus.CardanoConsensusConfig Consensus.StandardCrypto
  }

envSecurityParam :: Env -> Word64
envSecurityParam env = k
 where
  Consensus.SecurityParam k =
    HFC.hardForkConsensusConfigK $
      envConsensusConfig env

-- | How to do validation when applying a block to a ledger state.
data ValidationMode
  = -- | Do all validation implied by the ledger layer's 'applyBlock`.
    FullValidation
  | -- | Only check that the previous hash from the block matches the head hash of
    -- the ledger state.
    QuickValidation

-- The function 'tickThenReapply' does zero validation, so add minimal
-- validation ('blockPrevHash' matches the tip hash of the 'LedgerState'). This
-- was originally for debugging but the check is cheap enough to keep.
applyBlock'
  :: Env
  -> LedgerState
  -> ValidationMode
  -> Consensus.CardanoBlock Consensus.StandardCrypto
  -> Either LedgerStateError LedgerStateEvents
applyBlock' env oldState validationMode block = do
  let config = envLedgerConfig env
      stateOld = clsState oldState
  case validationMode of
    FullValidation -> tickThenApply config block stateOld
    QuickValidation -> tickThenReapplyCheckHash config block stateOld

applyBlockWithEvents
  :: Env
  -> LedgerState
  -> Bool
  -- ^ True to validate
  -> Consensus.CardanoBlock Consensus.StandardCrypto
  -> Either LedgerStateError LedgerStateEvents
applyBlockWithEvents env oldState enableValidation block = do
  let config = envLedgerConfig env
      stateOld = clsState oldState
  if enableValidation
    then tickThenApply config block stateOld
    else tickThenReapplyCheckHash config block stateOld

-- Like 'Consensus.tickThenReapply' but also checks that the previous hash from
-- the block matches the head hash of the ledger state.
tickThenReapplyCheckHash
  :: Consensus.CardanoLedgerConfig Consensus.StandardCrypto
  -> Consensus.CardanoBlock Consensus.StandardCrypto
  -> Consensus.CardanoLedgerState Consensus.StandardCrypto
  -> Either LedgerStateError LedgerStateEvents
tickThenReapplyCheckHash cfg block lsb =
  if Consensus.blockPrevHash block == Ledger.ledgerTipHash lsb
    then
      Right . toLedgerStateEvents $
        Ledger.tickThenReapplyLedgerResult cfg block lsb
    else
      Left $
        ApplyBlockHashMismatch $
          mconcat
            [ "Ledger state hash mismatch. Ledger head is slot "
            , textShow $
                Slot.unSlotNo $
                  Slot.fromWithOrigin
                    (Slot.SlotNo 0)
                    (Ledger.ledgerTipSlot lsb)
            , " hash "
            , renderByteArray $
                unChainHash $
                  Ledger.ledgerTipHash lsb
            , " but block previous hash is "
            , renderByteArray (unChainHash $ Consensus.blockPrevHash block)
            , " and block current hash is "
            , renderByteArray $
                BSS.fromShort $
                  HFC.getOneEraHash $
                    Ouroboros.Network.Block.blockHash block
            , "."
            ]

-- Like 'Consensus.tickThenReapply' but also checks that the previous hash from
-- the block matches the head hash of the ledger state.
tickThenApply
  :: Consensus.CardanoLedgerConfig Consensus.StandardCrypto
  -> Consensus.CardanoBlock Consensus.StandardCrypto
  -> Consensus.CardanoLedgerState Consensus.StandardCrypto
  -> Either LedgerStateError LedgerStateEvents
tickThenApply cfg block lsb =
  either (Left . ApplyBlockError) (Right . toLedgerStateEvents) $
    runExcept $
      Ledger.tickThenApplyLedgerResult cfg block lsb

renderByteArray :: ByteArrayAccess bin => bin -> Text
renderByteArray =
  Text.decodeUtf8 . Base16.encode . Data.ByteArray.convert

unChainHash :: Ouroboros.Network.Block.ChainHash (Consensus.CardanoBlock era) -> ByteString
unChainHash ch =
  case ch of
    Ouroboros.Network.Block.GenesisHash -> "genesis"
    Ouroboros.Network.Block.BlockHash bh -> BSS.fromShort (HFC.getOneEraHash bh)

data LeadershipError
  = LeaderErrDecodeLedgerStateFailure
  | LeaderErrDecodeProtocolStateFailure (LBS.ByteString, DecoderError)
  | LeaderErrDecodeProtocolEpochStateFailure DecoderError
  | LeaderErrGenesisSlot
  | LeaderErrStakePoolHasNoStake PoolId
  | LeaderErrStakeDistribUnstable
      SlotNo
      -- ^ Current slot
      SlotNo
      -- ^ Stable after
      SlotNo
      -- ^ Stability window size
      SlotNo
      -- ^ Predicted last slot of the epoch
  | LeaderErrSlotRangeCalculationFailure Text
  | LeaderErrCandidateNonceStillEvolving
  deriving Show

instance Api.Error LeadershipError where
  prettyError = \case
    LeaderErrDecodeLedgerStateFailure ->
      "Failed to successfully decode ledger state"
    LeaderErrDecodeProtocolStateFailure (_, decErr) ->
      mconcat
        [ "Failed to successfully decode protocol state: "
        , pretty (LT.toStrict . toLazyText $ build decErr)
        ]
    LeaderErrGenesisSlot ->
      "Leadership schedule currently cannot be calculated from genesis"
    LeaderErrStakePoolHasNoStake poolId ->
      "The stake pool: " <> pshow poolId <> " has no stake"
    LeaderErrDecodeProtocolEpochStateFailure decoderError ->
      "Failed to successfully decode the current epoch state: " <> pshow decoderError
    LeaderErrStakeDistribUnstable curSlot stableAfterSlot stabWindow predictedLastSlot ->
      mconcat
        [ "The current stake distribution is currently unstable and therefore we cannot predict "
        , "the following epoch's leadership schedule. Please wait until : " <> pshow stableAfterSlot
        , " before running the leadership-schedule command again. \nCurrent slot: " <> pshow curSlot
        , " \nStability window: " <> pshow stabWindow
        , " \nCalculated last slot of current epoch: " <> pshow predictedLastSlot
        ]
    LeaderErrSlotRangeCalculationFailure e ->
      "Error while calculating the slot range: " <> pretty e
    LeaderErrCandidateNonceStillEvolving ->
      "Candidate nonce is still evolving"

nextEpochEligibleLeadershipSlots
  :: forall era
   . ()
  => ShelleyBasedEra era
  -> ShelleyGenesis Consensus.StandardCrypto
  -> SerialisedCurrentEpochState era
  -- ^ We need the mark stake distribution in order to predict
  --   the following epoch's leadership schedule
  -> ProtocolState era
  -> PoolId
  -- ^ Potential slot leading stake pool
  -> SigningKey VrfKey
  -- ^ VRF signing key of the stake pool
  -> Ledger.PParams (ShelleyLedgerEra era)
  -> EpochInfo (Either Text)
  -> (ChainTip, EpochNo)
  -> Either LeadershipError (Set SlotNo)
nextEpochEligibleLeadershipSlots sbe sGen serCurrEpochState ptclState poolid (VrfSigningKey vrfSkey) pp eInfo (cTip, currentEpoch) =
  shelleyBasedEraConstraints sbe $ do
    (_, currentEpochLastSlot) <-
      first LeaderErrSlotRangeCalculationFailure $
        Slot.epochInfoRange eInfo currentEpoch

    (firstSlotOfEpoch, lastSlotofEpoch) <-
      first LeaderErrSlotRangeCalculationFailure $
        Slot.epochInfoRange eInfo (currentEpoch `Slot.addEpochInterval` Slot.EpochInterval 1)

    -- First we check if we are within 3k/f slots of the end of the current epoch.
    -- Why? Because the stake distribution is stable at this point.
    -- k is the security parameter
    -- f is the active slot coefficient
    let stabilityWindowR :: Rational
        stabilityWindowR = fromIntegral (3 * sgSecurityParam sGen) / Ledger.unboundRational (sgActiveSlotsCoeff sGen)
        stabilityWindowSlots :: SlotNo
        stabilityWindowSlots = fromIntegral @Word64 $ floor $ fromRational @Double stabilityWindowR
        stableStakeDistribSlot = currentEpochLastSlot - stabilityWindowSlots

    case cTip of
      ChainTipAtGenesis -> Left LeaderErrGenesisSlot
      ChainTip tip _ _ ->
        if tip > stableStakeDistribSlot
          then return ()
          else
            Left $
              LeaderErrStakeDistribUnstable tip stableStakeDistribSlot stabilityWindowSlots currentEpochLastSlot

    chainDepState <-
      first LeaderErrDecodeProtocolStateFailure $
        decodeProtocolState ptclState

    -- We need the candidate nonce, the previous epoch's last block header hash
    -- and the extra entropy from the protocol parameters. We then need to combine them
    -- with the (⭒) operator.
    let Consensus.PraosNonces{Consensus.candidateNonce, Consensus.evolvingNonce} =
          Consensus.getPraosNonces (Proxy @(Api.ConsensusProtocol era)) chainDepState

    -- Let's do a nonce check. The candidate nonce and the evolving nonce should not be equal.
    when (evolvingNonce == candidateNonce) $
      Left LeaderErrCandidateNonceStillEvolving

    -- Get the previous epoch's last block header hash nonce
    let previousLabNonce =
          Consensus.previousLabNonce
            (Consensus.getPraosNonces (Proxy @(Api.ConsensusProtocol era)) chainDepState)
        extraEntropy :: Nonce
        extraEntropy =
          caseShelleyToAlonzoOrBabbageEraOnwards
            (const (pp ^. Core.ppExtraEntropyL))
            (const Ledger.NeutralNonce)
            sbe

        nextEpochsNonce = candidateNonce ⭒ previousLabNonce ⭒ extraEntropy

    -- Then we get the "mark" snapshot. This snapshot will be used for the next
    -- epoch's leadership schedule.
    CurrentEpochState cEstate <-
      first LeaderErrDecodeProtocolEpochStateFailure $
        decodeCurrentEpochState sbe serCurrEpochState

    let snapshot :: ShelleyAPI.SnapShot Consensus.StandardCrypto
        snapshot = ShelleyAPI.ssStakeMark $ ShelleyAPI.esSnapshots cEstate
        markSnapshotPoolDistr
          :: Map
              (SL.KeyHash 'SL.StakePool Consensus.StandardCrypto)
              (SL.IndividualPoolStake Consensus.StandardCrypto)
        markSnapshotPoolDistr = ShelleyAPI.unPoolDistr . ShelleyAPI.calculatePoolDistr $ snapshot

    let slotRangeOfInterest :: Core.EraPParams ledgerera => Core.PParams ledgerera -> Set SlotNo
        slotRangeOfInterest pp' =
          Set.filter
            (not . Ledger.isOverlaySlot firstSlotOfEpoch (pp' ^. Core.ppDG))
            $ Set.fromList [firstSlotOfEpoch .. lastSlotofEpoch]

    caseShelleyToAlonzoOrBabbageEraOnwards
      ( const
          (isLeadingSlotsTPraos (slotRangeOfInterest pp) poolid markSnapshotPoolDistr nextEpochsNonce vrfSkey f)
      )
      ( const
          (isLeadingSlotsPraos (slotRangeOfInterest pp) poolid markSnapshotPoolDistr nextEpochsNonce vrfSkey f)
      )
      sbe
 where
  globals = shelleyBasedEraConstraints sbe $ constructGlobals sGen eInfo $ pp ^. Core.ppProtocolVersionL

  f :: Ledger.ActiveSlotCoeff
  f = activeSlotCoeff globals

-- | Return slots a given stake pool operator is leading.
-- See Leader Value Calculation in the Shelley ledger specification.
-- We need the certified natural value from the VRF, active slot coefficient
-- and the stake proportion of the stake pool.
isLeadingSlotsTPraos
  :: forall v
   . ()
  => Crypto.Signable v Ledger.Seed
  => Crypto.VRFAlgorithm v
  => Crypto.ContextVRF v ~ ()
  => Set SlotNo
  -> PoolId
  -> Map
      (SL.KeyHash 'SL.StakePool Consensus.StandardCrypto)
      (SL.IndividualPoolStake Consensus.StandardCrypto)
  -> Consensus.Nonce
  -> Crypto.SignKeyVRF v
  -> Ledger.ActiveSlotCoeff
  -> Either LeadershipError (Set SlotNo)
isLeadingSlotsTPraos slotRangeOfInterest poolid snapshotPoolDistr eNonce vrfSkey activeSlotCoeff' = do
  let StakePoolKeyHash poolHash = poolid

  let certifiedVrf s = Crypto.evalCertified () (TPraos.mkSeed TPraos.seedL s eNonce) vrfSkey

  stakePoolStake <-
    ShelleyAPI.individualPoolStake
      <$> Map.lookup poolHash snapshotPoolDistr
      & note (LeaderErrStakePoolHasNoStake poolid)

  let isLeader s = TPraos.checkLeaderValue (Crypto.certifiedOutput (certifiedVrf s)) stakePoolStake activeSlotCoeff'

  return $ Set.filter isLeader slotRangeOfInterest

isLeadingSlotsPraos
  :: ()
  => Set SlotNo
  -> PoolId
  -> Map
      (SL.KeyHash 'SL.StakePool Consensus.StandardCrypto)
      (SL.IndividualPoolStake Consensus.StandardCrypto)
  -> Consensus.Nonce
  -> SL.SignKeyVRF Consensus.StandardCrypto
  -> Ledger.ActiveSlotCoeff
  -> Either LeadershipError (Set SlotNo)
isLeadingSlotsPraos slotRangeOfInterest poolid snapshotPoolDistr eNonce vrfSkey activeSlotCoeff' = do
  let StakePoolKeyHash poolHash = poolid

  stakePoolStake <-
    note (LeaderErrStakePoolHasNoStake poolid) $
      ShelleyAPI.individualPoolStake <$> Map.lookup poolHash snapshotPoolDistr

  let isLeader slotNo = checkLeaderNatValue certifiedNatValue stakePoolStake activeSlotCoeff'
       where
        rho = VRF.evalCertified () (mkInputVRF slotNo eNonce) vrfSkey
        certifiedNatValue = vrfLeaderValue (Proxy @Consensus.StandardCrypto) rho

  Right $ Set.filter isLeader slotRangeOfInterest

-- | Return the slots at which a particular stake pool operator is
-- expected to mint a block.
currentEpochEligibleLeadershipSlots
  :: forall era
   . ()
  => ShelleyBasedEra era
  -> ShelleyGenesis Consensus.StandardCrypto
  -> EpochInfo (Either Text)
  -> Ledger.PParams (ShelleyLedgerEra era)
  -> ProtocolState era
  -> PoolId
  -> SigningKey VrfKey
  -> SerialisedPoolDistribution era
  -> EpochNo
  -- ^ Current EpochInfo
  -> Either LeadershipError (Set SlotNo)
currentEpochEligibleLeadershipSlots sbe sGen eInfo pp ptclState poolid (VrfSigningKey vrkSkey) serPoolDistr currentEpoch =
  shelleyBasedEraConstraints sbe $ do
    chainDepState :: ChainDepState (Api.ConsensusProtocol era) <-
      first LeaderErrDecodeProtocolStateFailure $ decodeProtocolState ptclState

    -- We use the current epoch's nonce for the current leadership schedule
    -- calculation because the TICKN transition updates the epoch nonce
    -- at the start of the epoch.
    let epochNonce :: Nonce =
          Consensus.epochNonce (Consensus.getPraosNonces (Proxy @(Api.ConsensusProtocol era)) chainDepState)

    (firstSlotOfEpoch, lastSlotofEpoch) :: (SlotNo, SlotNo) <-
      first LeaderErrSlotRangeCalculationFailure $
        Slot.epochInfoRange eInfo currentEpoch

    setSnapshotPoolDistr <-
      first LeaderErrDecodeProtocolEpochStateFailure
        . fmap (SL.unPoolDistr . fromConsensusPoolDistr . unPoolDistr)
        $ decodePoolDistribution sbe serPoolDistr

    let slotRangeOfInterest :: Core.EraPParams ledgerera => Core.PParams ledgerera -> Set SlotNo
        slotRangeOfInterest pp' =
          Set.filter
            (not . Ledger.isOverlaySlot firstSlotOfEpoch (pp' ^. Core.ppDG))
            $ Set.fromList [firstSlotOfEpoch .. lastSlotofEpoch]

    caseShelleyToAlonzoOrBabbageEraOnwards
      ( const
          (isLeadingSlotsTPraos (slotRangeOfInterest pp) poolid setSnapshotPoolDistr epochNonce vrkSkey f)
      )
      ( const
          (isLeadingSlotsPraos (slotRangeOfInterest pp) poolid setSnapshotPoolDistr epochNonce vrkSkey f)
      )
      sbe
 where
  globals = shelleyBasedEraConstraints sbe $ constructGlobals sGen eInfo $ pp ^. Core.ppProtocolVersionL

  f :: Ledger.ActiveSlotCoeff
  f = activeSlotCoeff globals

constructGlobals
  :: ShelleyGenesis Consensus.StandardCrypto
  -> EpochInfo (Either Text)
  -> Ledger.ProtVer
  -> Globals
constructGlobals sGen eInfo (Ledger.ProtVer majorPParamsVer _) =
  Ledger.mkShelleyGlobals sGen eInfo majorPParamsVer

--------------------------------------------------------------------------

-- | Type isomorphic to bool, representing condition check result
data ConditionResult
  = ConditionNotMet
  | ConditionMet
  deriving (Read, Show, Enum, Bounded, Ord, Eq)

toConditionResult :: Bool -> ConditionResult
toConditionResult False = ConditionNotMet
toConditionResult True = ConditionMet

fromConditionResult :: ConditionResult -> Bool
fromConditionResult ConditionNotMet = False
fromConditionResult ConditionMet = True

data AnyNewEpochState where
  AnyNewEpochState
    :: ShelleyBasedEra era
    -> ShelleyAPI.NewEpochState (ShelleyLedgerEra era)
    -> AnyNewEpochState

instance Show AnyNewEpochState where
  showsPrec p (AnyNewEpochState sbe ledgerNewEpochState) =
    shelleyBasedEraConstraints sbe $ showsPrec p ledgerNewEpochState

-- | Reconstructs the ledger's new epoch state and applies a supplied condition to it for every block. This
-- function only terminates if the condition is met or we have reached the termination epoch. We need to
-- provide a termination epoch otherwise blocks would be applied indefinitely.
foldEpochState
  :: forall t m s
   . MonadIOTransError FoldBlocksError t m
  => NodeConfigFile 'In
  -- ^ Path to the cardano-node config file (e.g. <path to cardano-node project>/configuration/cardano/mainnet-config.json)
  -> SocketPath
  -- ^ Path to local cardano-node socket. This is the path specified by the @--socket-path@ command line option when running the node.
  -> ValidationMode
  -> EpochNo
  -- ^ Termination epoch
  -> s
  -- ^ an initial value for the condition state
  -> ( AnyNewEpochState
       -> SlotNo
       -> BlockNo
       -> StateT s IO ConditionResult
     )
  -- ^ Condition you want to check against the new epoch state.
  --
  --   'SlotNo' - Current (not necessarily the tip) slot number
  --
  --   'BlockNo' - Current (not necessarily the tip) block number
  --
  -- Note: This function can safely assume no rollback will occur even though
  -- internally this is implemented with a client protocol that may require
  -- rollback. This is achieved by only calling the accumulator on states/blocks
  -- that are older than the security parameter, k. This has the side effect of
  -- truncating the last k blocks before the node's tip.
  -> t m (ConditionResult, s)
  -- ^ The final state
foldEpochState nodeConfigFilePath socketPath validationMode terminationEpoch initialResult checkCondition = handleExceptions $ do
  -- NOTE this was originally implemented with a non-pipelined client then
  -- changed to a pipelined client for a modest speedup:
  --  * Non-pipelined: 1h  0m  19s
  --  * Pipelined:        46m  23s

  (env, ledgerState) <-
    modifyError FoldBlocksInitialLedgerStateError $
      initialLedgerState nodeConfigFilePath

  -- Place to store the accumulated state
  -- This is a bit ugly, but easy.
  errorIORef <- modifyError FoldBlocksIOException . liftIO $ newIORef Nothing
  -- This needs to be a full MVar by default. It serves as a mutual exclusion lock when executing
  -- 'checkCondition' to ensure that states 's' are processed in order. This is assured by MVar fairness.
  stateMv <- modifyError FoldBlocksIOException . liftIO $ newMVar (ConditionNotMet, initialResult)

  -- Derive the NetworkId as described in network-magic.md from the
  -- cardano-ledger-specs repo.
  let byronConfig =
        (\(Consensus.WrapPartialLedgerConfig (Consensus.ByronPartialLedgerConfig bc _) :* _) -> bc)
          . HFC.getPerEraLedgerConfig
          . HFC.hardForkLedgerConfigPerEra
          $ envLedgerConfig env

      networkMagic =
        NetworkMagic $
          unProtocolMagicId $
            Cardano.Chain.Genesis.gdProtocolMagicId $
              Cardano.Chain.Genesis.configGenesisData byronConfig

      networkId' = case Cardano.Chain.Genesis.configReqNetMagic byronConfig of
        RequiresNoMagic -> Mainnet
        RequiresMagic -> Testnet networkMagic

      cardanoModeParams = CardanoModeParams . EpochSlots $ 10 * envSecurityParam env

  -- Connect to the node.
  let connectInfo =
        LocalNodeConnectInfo
          { localConsensusModeParams = cardanoModeParams
          , localNodeNetworkId = networkId'
          , localNodeSocketPath = socketPath
          }

  modifyError FoldBlocksIOException $
    liftIO $
      connectToLocalNode
        connectInfo
        (protocols stateMv errorIORef env ledgerState)

  liftIO (readIORef errorIORef) >>= \case
    Just err -> throwError $ FoldBlocksApplyBlockError err
    Nothing -> modifyError FoldBlocksIOException . liftIO $ readMVar stateMv
 where
  protocols
    :: ()
    => MVar (ConditionResult, s)
    -> IORef (Maybe LedgerStateError)
    -> Env
    -> LedgerState
    -> LocalNodeClientProtocolsInMode
  protocols stateMv errorIORef env ledgerState =
    LocalNodeClientProtocols
      { localChainSyncClient =
          LocalChainSyncClientPipelined (chainSyncClient 50 stateMv errorIORef env ledgerState)
      , localTxSubmissionClient = Nothing
      , localStateQueryClient = Nothing
      , localTxMonitoringClient = Nothing
      }

  -- \| Defines the client side of the chain sync protocol.
  chainSyncClient
    :: Word16
    -- \^ The maximum number of concurrent requests.
    -> MVar (ConditionResult, s)
    -- \^ State accumulator. Written to on every block.
    -> IORef (Maybe LedgerStateError)
    -- \^ Resulting error if any. Written to once on protocol
    -- completion.
    -> Env
    -> LedgerState
    -> CSP.ChainSyncClientPipelined
        BlockInMode
        ChainPoint
        ChainTip
        IO
        ()
  -- \^ Client returns maybe an error.
  chainSyncClient pipelineSize stateMv errorIORef' env ledgerState0 =
    CSP.ChainSyncClientPipelined $
      pure $
        clientIdle_RequestMoreN Origin Origin Zero initialLedgerStateHistory
   where
    initialLedgerStateHistory = Seq.singleton (0, (ledgerState0, []), Origin)

    clientIdle_RequestMoreN
      :: WithOrigin BlockNo
      -> WithOrigin BlockNo
      -> Nat n -- Number of requests inflight.
      -> LedgerStateHistory
      -> CSP.ClientPipelinedStIdle n BlockInMode ChainPoint ChainTip IO ()
    clientIdle_RequestMoreN clientTip serverTip n knownLedgerStates =
      case pipelineDecisionMax pipelineSize n clientTip serverTip of
        Collect -> case n of
          Succ predN -> CSP.CollectResponse Nothing (clientNextN predN knownLedgerStates)
        _ ->
          CSP.SendMsgRequestNextPipelined
            (pure ())
            (clientIdle_RequestMoreN clientTip serverTip (Succ n) knownLedgerStates)

    clientNextN
      :: Nat n -- Number of requests inflight.
      -> LedgerStateHistory
      -> CSP.ClientStNext n BlockInMode ChainPoint ChainTip IO ()
    clientNextN n knownLedgerStates =
      CSP.ClientStNext
        { CSP.recvMsgRollForward = \blockInMode@(BlockInMode era (Block (BlockHeader slotNo _ currBlockNo) _)) serverChainTip -> do
            let newLedgerStateE =
                  applyBlock
                    env
                    ( maybe
                        (error "Impossible! Missing Ledger state")
                        (\(_, (ledgerState, _), _) -> ledgerState)
                        (Seq.lookup 0 knownLedgerStates)
                    )
                    validationMode
                    blockInMode
            case forEraMaybeEon era of
              Nothing ->
                let !err = Just ByronEraUnsupported
                 in clientIdle_DoneNwithMaybeError n err
              Just sbe ->
                case newLedgerStateE of
                  Left err -> clientIdle_DoneNwithMaybeError n (Just err)
                  Right new@(newLedgerState, ledgerEvents) -> do
                    let (knownLedgerStates', _) = pushLedgerState env knownLedgerStates slotNo new blockInMode
                        newClientTip = At currBlockNo
                        newServerTip = fromChainTip serverChainTip
                    case getNewEpochState sbe $ clsState newLedgerState of
                      Left e ->
                        let !err = Just e
                         in clientIdle_DoneNwithMaybeError n err
                      Right lState -> do
                        let newEpochState = AnyNewEpochState sbe lState
                        -- Run the condition function in an exclusive lock.
                        -- There can be only one place where `takeMVar stateMv` exists otherwise this
                        -- code will deadlock!
                        condition <- bracket (takeMVar stateMv) (tryPutMVar stateMv) $ \(_prevCondition, previousState) -> do
                          updatedState@(!newCondition, !_) <-
                            runStateT (checkCondition newEpochState slotNo currBlockNo) previousState
                          putMVar stateMv updatedState
                          pure newCondition
                        -- Have we reached the termination epoch?
                        case atTerminationEpoch terminationEpoch ledgerEvents of
                          Just !currentEpoch -> do
                            -- confirmed this works: error $ "atTerminationEpoch: Terminated at: " <> show currentEpoch
                            let !err = Just $ TerminationEpochReached currentEpoch
                            clientIdle_DoneNwithMaybeError n err
                          Nothing -> do
                            case condition of
                              ConditionMet ->
                                let !noError = Nothing
                                 in clientIdle_DoneNwithMaybeError n noError
                              ConditionNotMet -> return $ clientIdle_RequestMoreN newClientTip newServerTip n knownLedgerStates'
        , CSP.recvMsgRollBackward = \chainPoint serverChainTip -> do
            let newClientTip = Origin -- We don't actually keep track of blocks so we temporarily "forget" the tip.
                newServerTip = fromChainTip serverChainTip
                truncatedKnownLedgerStates = case chainPoint of
                  ChainPointAtGenesis -> initialLedgerStateHistory
                  ChainPoint slotNo _ -> rollBackLedgerStateHist knownLedgerStates slotNo
            return (clientIdle_RequestMoreN newClientTip newServerTip n truncatedKnownLedgerStates)
        }

    clientIdle_DoneNwithMaybeError
      :: Nat n -- Number of requests inflight.
      -> Maybe LedgerStateError -- Return value (maybe an error)
      -> IO (CSP.ClientPipelinedStIdle n BlockInMode ChainPoint ChainTip IO ())
    clientIdle_DoneNwithMaybeError n errorMay = case n of
      Succ predN -> do
        return (CSP.CollectResponse Nothing (clientNext_DoneNwithMaybeError predN errorMay)) -- Ignore remaining message responses
      Zero -> do
        atomicModifyIORef' errorIORef' . const $ (errorMay, ())
        return (CSP.SendMsgDone ())

    clientNext_DoneNwithMaybeError
      :: Nat n -- Number of requests inflight.
      -> Maybe LedgerStateError -- Return value (maybe an error)
      -> CSP.ClientStNext n BlockInMode ChainPoint ChainTip IO ()
    clientNext_DoneNwithMaybeError n errorMay =
      CSP.ClientStNext
        { CSP.recvMsgRollForward = \_ _ -> clientIdle_DoneNwithMaybeError n errorMay
        , CSP.recvMsgRollBackward = \_ _ -> clientIdle_DoneNwithMaybeError n errorMay
        }

    fromChainTip :: ChainTip -> WithOrigin BlockNo
    fromChainTip ct = case ct of
      ChainTipAtGenesis -> Origin
      ChainTip _ _ bno -> At bno

atTerminationEpoch :: EpochNo -> [LedgerEvent] -> Maybe EpochNo
atTerminationEpoch terminationEpoch events =
  listToMaybe
    [ currentEpoch'
    | PoolReap poolReapDets <- events
    , let currentEpoch' = prdEpochNo poolReapDets
    , currentEpoch' >= terminationEpoch
    ]

handleExceptions
  :: MonadIOTransError FoldBlocksError t m
  => ExceptT FoldBlocksError IO a
  -> t m a
handleExceptions = liftEither <=< liftIO . runExceptT . flip catches handlers
 where
  handlers =
    [ Handler $ throwError . FoldBlocksIOException
    , Handler $ throwError . FoldBlocksMuxError
    ]

-- WARNING: Do NOT use this function anywhere else except in its current call sites.
-- This is a temporary work around.
fromConsensusPoolDistr :: Consensus.PoolDistr c -> SL.PoolDistr c
fromConsensusPoolDistr cpd =
  SL.PoolDistr
    { SL.unPoolDistr = Map.map toLedgerIndividualPoolStake $ Consensus.unPoolDistr cpd
    , SL.pdTotalActiveStake = SL.CompactCoin 0
    }

-- WARNING: Do NOT use this function anywhere else except in its current call sites.
-- This is a temporary work around.
toLedgerIndividualPoolStake :: Consensus.IndividualPoolStake c -> SL.IndividualPoolStake c
toLedgerIndividualPoolStake ips =
  SL.IndividualPoolStake
    { SL.individualPoolStake = Consensus.individualPoolStake ips
    , SL.individualPoolStakeVrf = Consensus.individualPoolStakeVrf ips
    , SL.individualTotalPoolStake = SL.CompactCoin 0
    }
