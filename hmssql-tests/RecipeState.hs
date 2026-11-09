-- | Assertions over the response's cancellation progression.
module RecipeState (attentionSent, acknowledged, abandoned, ended) where
import Data.IORef
import Hmssql.Connection.Internal
attentionSent, acknowledged, abandoned :: ActiveResponse -> IO Bool
attentionSent ar = (`elem` [AttentionSent, AttentionAcknowledged]) <$> readIORef (arCancellation ar)
acknowledged ar = (== AttentionAcknowledged) <$> readIORef (arCancellation ar)
abandoned ar = (/= Running) <$> readIORef (arCancellation ar)
ended :: ReadState -> Bool
ended = readFinalPacket
