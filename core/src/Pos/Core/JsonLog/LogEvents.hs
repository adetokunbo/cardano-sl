{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeSynonymInstances       #-}

-- | Some types for json logging.
module Pos.Core.JsonLog.LogEvents
       ( HasJsonLogConfig (..)
       , InvReqDataFlowLog (..)
       , JLEvent(..)
       , JLTxS (..)
       , JLTxR (..)
       , JLMemPool (..)
       , JLBlock (..)
       , JLTimedEvent (..)
       , JsonLogConfig (..)
       , MemPoolModifyReason (..)
       , appendJL
       , jsonLogConfigFromHandle
       , jsonLogDefault
       , fromJLSlotId
       , fromJLSlotIdUnsafe
       ) where

import           Universum

import           Control.Monad.Except (MonadError)
import           Data.Aeson (FromJSON, ToJSON, Value (..), encode, object,
                     parseJSON, toJSON, (.:), (.=))
import           Data.Aeson.Options (defaultOptions)
import           Data.Aeson.TH (deriveJSON)
import           Data.Aeson.Types (typeMismatch)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.HashMap.Strict as HMS

import           Pos.Core (EpochIndex (..), SlotCount, SlotId (..),
                     mkLocalSlotIndex)
import           Pos.Core.JsonLog.JsonLogT (JsonLogConfig (..))
import qualified Pos.Core.JsonLog.JsonLogT as JL
import           Pos.Util.Util (realTime)
import           Pos.Util.Wlog (WithLogger)

type BlockId = Text
type TxId = Text
type JLSlotId = (Word64, Word16)


-- | Json log of one block with corresponding 'BlockId'.
data JLBlock = JLBlock
    { jlHash      :: !BlockId
    , jlPrevBlock :: !BlockId
    , jlTxs       :: ![TxId]
    , jlSlot      :: !JLSlotId
    } deriving Show

-- | Json log of one transaction sent from the (light) wallet.
data JLTxS = JLTxS
    { jlsNodeId :: !Text
    , jlsTxId   :: !Text
    , jlsInvReq :: !InvReqDataFlowLog
    } deriving Show

-- | Json log of one transaction being received by a node.
data JLTxR = JLTxR
    { jlrTxId  :: !Text
    , jlrError :: !(Maybe Text)
    } deriving Show

-- | Enumeration of all reasons for modifying the mempool.
data MemPoolModifyReason =
      -- | Apply a block.
      ApplyBlock
      -- | Apply a block, with rollback.
    | ApplyBlockWithRollback
      -- | Include a transaction. It came from this peer.
    | ProcessTransaction
    deriving Show

-- | Json log of one mempool modification.
data JLMemPool = JLMemPool
    { -- | Reason for modifying the mempool
      jlmReason      :: !MemPoolModifyReason
      -- | Queue length when trying to modify the mempool (not including this
      --   modifier, so it could be 0).
    , jlmQueueLength :: !Int
      -- | Time spent waiting for the lock (microseconds)
    , jlmWait        :: !Integer
      -- | Time spent doing the modification (microseconds, while holding the lock).
    , jlmModify      :: !Integer
      -- | Size of the mempool before the modification.
    , jlmSizeBefore  :: !Int
      -- | Size of the mempool after the modification.
    , jlmSizeAfter   :: !Int
      -- | How much memory was allocated during the modification.
    , jlmAllocated   :: !Int64
    } deriving Show

-- | Json log event.
data JLEvent = JLCreatedBlock !JLBlock
             | JLAdoptedBlock !BlockId
             | JLTpsStat !Int
             | JLTxSent !JLTxS
             | JLTxReceived !JLTxR
             | JLMemPoolEvent !JLMemPool
  deriving (Show, Generic)

-- | 'JLEvent' with 'Timestamp' -- corresponding time of this event.
data JLTimedEvent = JLTimedEvent
    { jlTimestamp :: !Integer
    , jlEvent     :: !JLEvent
    } deriving Show

-- -----------------------------------------------------------------------------
-- This type was originally in Pos.Infra.Communication.Relay.Logic but was moved
-- here so the package dependency graph could be re-arranged.

data InvReqDataFlowLog =
      InvReqAccepted
        { invReqStart    :: !Integer
        , invReqReceived :: !Integer
        , invReqSent     :: !Integer
        , invReqClosed   :: !Integer
        }
    | InvReqRejected
        { invReqStart    :: !Integer
        , invReqReceived :: !Integer
        }
    | InvReqException !Text
    deriving (Eq, Generic, Show)

instance ToJSON InvReqDataFlowLog where
    toJSON (InvReqAccepted str rece sen closed) =
        object [ "invReqAccepted" .=
            object [ "reqStart" .=  toJSON str
                   , "reqReceived" .= toJSON rece
                   , "reqSent" .= toJSON sen
                   , "reqClosed" .= toJSON closed
                   ]
               ]
    toJSON (InvReqRejected str rece) =
        object [ "invReqRejected" .=
            object [ "reqStart" .= toJSON str
                   , "reqReceived" .= rece
                   ]
               ]
    toJSON (InvReqException exception) =
            object [ "invReqException" .= toJSON exception]

instance FromJSON InvReqDataFlowLog where
    parseJSON (Object o)
        | HMS.member "invReqAccepted" o = do
            invReqAccO <- o .: "invReqAccepted"
            str <- invReqAccO .: "reqStart"
            rece <- invReqAccO .: "reqReceived"
            sen <- invReqAccO .: "reqSent"
            closed <- invReqAccO .: "reqClosed"
            return $ InvReqAccepted str rece sen closed
        | HMS.member "invReqRejected" o = do
            invReqRecO <- o .: "invReqRejected"
            str <- invReqRecO .: "reqStart"
            rece <- invReqRecO .: "reqReceived"
            return $ InvReqRejected str rece
        | HMS.member "invReqException" o =
            InvReqException <$> (o .: "invReqException")
        | otherwise = fail "Incorrect JSON encoding for InvReqDataFlowLog"
    parseJSON invalid = typeMismatch "InvReqDataFlowLog" invalid

$(deriveJSON defaultOptions ''MemPoolModifyReason)
$(deriveJSON defaultOptions ''JLBlock)
$(deriveJSON defaultOptions ''JLEvent)
$(deriveJSON defaultOptions ''JLTimedEvent)
$(deriveJSON defaultOptions ''JLTxS)
$(deriveJSON defaultOptions ''JLTxR)
$(deriveJSON defaultOptions ''JLMemPool)

-- | Get 'SlotId' from 'JLSlotId'.
fromJLSlotId :: MonadError Text m => SlotCount -> JLSlotId -> m SlotId
fromJLSlotId epochSlots (ep, sl) =
    SlotId (EpochIndex ep) <$> mkLocalSlotIndex epochSlots sl

-- | Get 'SlotId' from 'JLSlotId'.
fromJLSlotIdUnsafe :: SlotCount -> JLSlotId -> SlotId
fromJLSlotIdUnsafe epochSlots x = case fromJLSlotId epochSlots x of
    Right y -> y
    Left  _ -> error "illegal slot id"

-- | Append event into log by given 'FilePath'.
appendJL :: (MonadIO m) => FilePath -> JLEvent -> m ()
appendJL path ev = liftIO $ do
  time <- realTime -- TODO: Do we want to mock time in logs?
  LBS.appendFile path . encode $ JLTimedEvent (fromIntegral time) ev

jsonLogConfigFromHandle :: MonadIO m => Handle -> m JsonLogConfig
jsonLogConfigFromHandle h = do
    v <- newMVar h
    return $ JsonLogConfig v (\_ -> return True)

class HasJsonLogConfig ctx where
    jsonLogConfig :: Lens' ctx JsonLogConfig

jsonLogDefault
    :: (ToJSON a, MonadReader ctx m, HasJsonLogConfig ctx, MonadCatch m,
        MonadIO m, WithLogger m)
    => a -> m ()
jsonLogDefault x = do
    jlc <- view jsonLogConfig
    JL.jsonLogDefault jlc x
