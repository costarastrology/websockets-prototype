{-| Common helper functions.

-}
module Utils where

import           Data.Aeson                     ( Options(..)
                                                , SumEncoding(..)
                                                , defaultOptions
                                                )
import           Data.Time                      ( defaultTimeLocale
                                                , formatTime
                                                , getCurrentTime
                                                )

-- | Some reasonable JSON encoding/decoding options for our top-level
-- websocket & redis message types.
msgJsonOptions :: Options
msgJsonOptions = defaultOptions
    { allNullaryToStringTag = False
    , unwrapUnaryRecords    = False
    , tagSingleConstructors = True
    , sumEncoding           = TaggedObject { tagFieldName      = "type"
                                           , contentsFieldName = "contents"
                                           }
    }

-- | JSON encoding/decoding options for the XyzData types nested in
-- a top-level message type.
msgDataJsonOptions :: Options
msgDataJsonOptions = msgJsonOptions { tagSingleConstructors = False }

-- | Render the current time in a nice format for logging.
getFormattedTime :: IO String
getFormattedTime =
    formatTime defaultTimeLocale "[%H:%M:%S] " <$> getCurrentTime
