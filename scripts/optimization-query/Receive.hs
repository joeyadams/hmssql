module Main where
import Hmssql.Connection.Backend
import Hmssql.Connection.Internal (newBufferedRecv)
import qualified Data.ByteString as B
import Foreign.Marshal.Utils
import Control.Monad
import Control.Exception
import GHC.Stats
import System.Mem
main = do
 let backend = Backend (\ptr n -> fillBytes ptr 0 n >> pure n) (const (pure ())) (const (pure ())) (pure ()) (pure ()) (pure ()) Nothing
 recv <- newBufferedRecv backend
 recv 32 >>= evaluate . B.length
 performGC
 before <- getRTSStats
 replicateM_ 10000 (recv 32 >>= evaluate . B.length)
 performGC
 after <- getRTSStats
 print (allocated_bytes after-allocated_bytes before,max_live_bytes after)
