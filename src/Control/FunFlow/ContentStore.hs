{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Hash addressed store in file system.
--
-- A store associates a 'Control.FunFlow.ContentHashable.ContentHash'
-- with a directory subtree. A subtree can be either
-- 'Control.FunFlow.ContentStore.Missing',
-- 'Control.FunFlow.ContentStore.Pending, or
-- 'Control.FunFlow.ContentStore.Complete'.
-- The state of subtrees is persisted on the file system.
--
-- The store is thread-safe and multi-process safe.
--
-- It is assumed that the user that the process is running under is the owner
-- of the store root, or has permission to create it if missing.
--
-- It is assumed that the store root and its immediate contents are not modified
-- externally. The contents of subtrees may be modified externally while the
-- subtree is marked as pending.
--
-- __Implementation note:__
--
-- Two file-system features are used to persist the state of a subtree,
-- namely whether it exists and whether it is writable.
--
-- @
--   exists   writable    state
--   ----------------------------
--                       missing
--     X          X      pending
--     X                 complete
-- @
module Control.FunFlow.ContentStore
  ( Status (..)
  , Status_
  , Update (..)
  , StoreError (..)
  , ContentStore
  , Item
  , itemPath
  , root
  , open
  , close
  , withStore
  , listAll
  , listPending
  , listComplete
  , listItems
  , query
  , isMissing
  , isPending
  , isComplete
  , lookup
  , lookupOrWait
  , waitUntilComplete
  , constructOrWait
  , constructIfMissing
  , markPending
  , markComplete
  , removeFailed
  , removeForcibly
  , removeItemForcibly
  ) where


import           Prelude                         hiding (lookup)

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.Async
import           Control.Concurrent.MVar
import           Control.Exception               (Exception, bracket_, catch,
                                                  throwIO)
import           Control.Lens
import           Control.Monad                   ((<=<), (>=>), forever, void)
import           Control.Monad.Catch             (MonadMask, bracket)
import           Control.Monad.IO.Class          (MonadIO, liftIO)
import           Crypto.Hash                     (hashUpdate)
import           Data.Bits                       (complement)
import qualified Data.ByteString.Char8           as C8
import           Data.Foldable                   (asum)
import           Data.List                       (foldl', stripPrefix)
import           Data.Maybe                      (fromMaybe)
import           Data.Monoid                     ((<>))
import qualified Data.Store
import           Data.String                     (IsString)
import           Data.Typeable                   (Typeable)
import           GHC.Generics                    (Generic)
import           GHC.IO.Device                   (SeekMode (AbsoluteSeek))
import           System.Directory                (removePathForcibly)
import           Path
import           Path.IO
import           System.FilePath                 (dropTrailingPathSeparator)
import           System.INotify
import           System.Posix.Files
import           System.Posix.IO
import           System.Posix.Types

import           Control.FunFlow.ContentHashable (ContentHash,
                                                  ContentHashable (..),
                                                  DirectoryContent (..),
                                                  contentHashUpdate_fingerprint,
                                                  encodeHash, pathToHash,
                                                  toBytes)


-- | Status of a subtree in the store.
data Status missing pending complete
  = Missing missing
  -- ^ The subtree does not exist, yet.
  | Pending pending
  -- ^ The subtree is under construction and not ready for consumption.
  | Complete complete
  -- ^ The subtree is complete and ready for consumption.
  deriving (Eq, Show)

type Status_ = Status () () ()

-- | Update about the status of a pending subtree.
data Update
  = Completed Item
  -- ^ The item is now completed and ready for consumption.
  | Failed
  -- ^ Constructing the item failed.
  deriving (Eq, Show)

-- | Errors that can occur when interacting with the store.
data StoreError
  = NotPending ContentHash
  -- ^ A subtree is not under construction when it should be.
  | AlreadyPending ContentHash
  -- ^ A subtree is already under construction when it should be missing.
  | AlreadyComplete ContentHash
  -- ^ A subtree is already complete when it shouldn't be.
  | CorruptedLink ContentHash FilePath
  -- ^ The link under the given hash points to an invalid path.
  deriving (Show, Typeable)
instance Exception StoreError

-- | A hash addressed store on the file system.
data ContentStore = ContentStore
  { storeRoot    :: Path Abs Dir
  -- ^ Subtrees are stored directly under this directory.
  , storeLock    :: MVar ()
  -- ^ One global lock on store metadata to ensure thread safety.
  -- The lock is taken when subtree state is changed or queried.
  , storeLockFd  :: Fd
  -- ^ One exclusive file lock to ensure multi-processing safety.
  -- Note, that file locks are shared between threads in a process,
  -- so that the file lock needs to be complemented by an `MVar`
  -- for thread-safety.
  , storeINotify :: INotify
  -- ^ Used to watch for updates on store items.
  }

-- | A completed item in the 'ContentStore'.
data Item = Item { itemHash :: ContentHash }
  deriving (Eq, Ord, Show, Generic)

instance ContentHashable Item where
  contentHashUpdate ctx item =
    flip contentHashUpdate_fingerprint item
    >=> pure . flip hashUpdate (toBytes $ itemHash item)
    $ ctx

instance Data.Store.Store Item

-- | The root directory of the store.
root :: ContentStore -> Path Abs Dir
root = storeRoot

-- | The store path of a completed item.
itemPath :: ContentStore -> Item -> Path Abs Dir
itemPath store = mkItemPath store . itemHash

-- | @open root@ opens a store under the given root directory.
--
-- The root directory is created if necessary.
--
-- It is not safe to have multiple store objects
-- refer to the same root directory.
open :: Path Abs Dir -> IO ContentStore
open storeRoot = do
  createDirIfMissing True storeRoot
  storeLockFd <- createFile (fromAbsFile $ lockPath storeRoot) ownerWriteMode
  setFileMode (fromAbsDir storeRoot) readOnlyRootDirMode
  storeLock <- newMVar ()
  storeINotify <- initINotify
  return ContentStore {..}

-- | Free the resources associated with the given store object.
--
-- The store object may not be used afterwards.
close :: ContentStore -> IO ()
close store = do
  takeMVar (storeLock store)
  closeFd (storeLockFd store)
  killINotify (storeINotify store)

-- | Open the under the given root and perform the given action.
-- Closes the store once the action is complete
--
-- See also: 'Control.FunFlow.ContentStore.open'
withStore :: (MonadIO m, MonadMask m)
  => Path Abs Dir -> (ContentStore -> m a) -> m a
withStore root' = bracket (liftIO $ open root') (liftIO . close)

-- | List all elements in the store
-- @(pending keys, completed keys, completed items)@.
listAll :: ContentStore -> IO ([ContentHash], [ContentHash], [Item])
listAll ContentStore {storeRoot} =
  foldr go ([], [], []) . fst <$> listDir storeRoot
  where
    go d prev@(builds, outs, items) = fromMaybe prev $ asum
      [ parsePending d >>= \x -> Just (x:builds, outs, items)
      , parseComplete d >>= \x -> Just (builds, x:outs, items)
      , parseItem d >>= \x -> Just (builds, outs, x:items)
      ]
    parsePending :: Path Abs Dir -> Maybe ContentHash
    parsePending = pathToHash <=< stripPrefix pendingPrefix . extractDir
    parseComplete :: Path Abs Dir -> Maybe ContentHash
    parseComplete = pathToHash <=< stripPrefix completePrefix . extractDir
    parseItem :: Path Abs Dir -> Maybe Item
    parseItem = fmap Item . pathToHash <=< stripPrefix itemPrefix . extractDir
    extractDir :: Path Abs Dir -> FilePath
    extractDir = dropTrailingPathSeparator . fromRelDir . dirname

-- | List all pending keys in the store.
listPending :: ContentStore -> IO [ContentHash]
listPending = fmap (^._1) . listAll

-- | List all completed keys in the store.
listComplete :: ContentStore -> IO [ContentHash]
listComplete = fmap (^._2) . listAll

-- | List all completed items in the store.
listItems :: ContentStore -> IO [Item]
listItems = fmap (^._3) . listAll

-- | Query for the state of a subtree.
query :: ContentStore -> ContentHash -> IO (Status () () ())
query store hash = withStoreLock store $
  internalQuery store hash >>= pure . \case
    Missing _ -> Missing ()
    Pending _ -> Pending ()
    Complete _ -> Complete ()

isMissing :: ContentStore -> ContentHash -> IO Bool
isMissing store hash = (== Missing ()) <$> query store hash

isPending :: ContentStore -> ContentHash -> IO Bool
isPending store hash = (== Pending ()) <$> query store hash

isComplete :: ContentStore -> ContentHash -> IO Bool
isComplete store hash = (== Complete ()) <$> query store hash

-- | Query a subtree and return it if completed.
lookup :: ContentStore -> ContentHash -> IO (Status () () Item)
lookup store hash = withStoreLock store $
  internalQuery store hash >>= \case
    Missing () -> return $ Missing ()
    Pending _ -> return $ Pending ()
    Complete item -> return $ Complete item

-- | Query a subtree and return it if completed.
-- Return an 'Control.Concurrent.Async' to await updates,
-- if it is already under construction.
lookupOrWait
  :: ContentStore
  -> ContentHash
  -> IO (Status () (Async Update) Item)
lookupOrWait store hash = withStoreLock store $
  internalQuery store hash >>= \case
    Complete item -> return $ Complete item
    Missing () -> return $ Missing ()
    Pending _ -> Pending <$> internalWatchPending store hash

-- | Query a subtree and block, if necessary, until it is completed or failed.
-- Returns 'Nothing' if the subtree is not in the store
-- and the subtree, otherwise.
waitUntilComplete :: ContentStore -> ContentHash -> IO (Maybe Item)
waitUntilComplete store hash = lookupOrWait store hash >>= \case
  Complete item -> return $ Just item
  Missing () -> return Nothing
  Pending a -> wait a >>= \case
    Completed item -> return $ Just item
    Failed -> return $ Nothing

-- | Atomically query the state of a subtree
-- and mark it as under construction if missing.
-- Return an 'Control.Concurrent.Async' to await updates,
-- if it is already under construction.
constructOrWait
  :: ContentStore
  -> ContentHash
  -> IO (Status (Path Abs Dir) (Async Update) Item)
constructOrWait store hash = withStoreLock store $
  internalQuery store hash >>= \case
    Complete item -> return $ Complete item
    Missing () -> withWritableStore store $
      Missing <$> createBuildDir store hash
    Pending _ -> Pending <$> internalWatchPending store hash

-- | Atomically query the state of a subtree
-- and mark it as under construction if missing.
constructIfMissing
  :: ContentStore
  -> ContentHash
  -> IO (Status (Path Abs Dir) () Item)
constructIfMissing store hash = withStoreLock store $
  internalQuery store hash >>= \case
    Complete item -> return $ Complete item
    Pending _ -> return $ Pending ()
    Missing () -> withWritableStore store $
      Missing <$> createBuildDir store hash

-- | Mark a non-existent subtree as under construction.
--
-- Creates the destination directory and returns its path.
--
-- See also: 'Control.FunFlow.ContentStore.constructIfMissing'.
markPending :: ContentStore -> ContentHash -> IO (Path Abs Dir)
markPending store hash = withStoreLock store $
  internalQuery store hash >>= \case
    Complete _ -> throwIO (AlreadyComplete hash)
    Pending _ -> throwIO (AlreadyPending hash)
    Missing () -> withWritableStore store $
      createBuildDir store hash

-- | Remove a subtree that was under construction.
markComplete :: ContentStore -> ContentHash -> IO Item
markComplete store inHash = withStoreLock store $
  internalQuery store inHash >>= \case
    Missing () -> throwIO (NotPending inHash)
    Complete _ -> throwIO (AlreadyComplete inHash)
    Pending build -> withWritableStore store $ do
      unsetWritableRecursively build
      -- XXX: Hashing large data can take some time,
      --   could we avoid locking the store for all that time?
      -- XXX: Take executable bit of files into account.
      outHash <- contentHash (DirectoryContent build)
      let out = mkItemPath store outHash
          link' = mkCompletePath store inHash
      doesDirExist out >>= \case
        True -> removeDir build
        False -> renameDir build out
      rel <- makeRelative (parent link') out
      let from' = dropTrailingPathSeparator $ fromAbsDir link'
          to' = dropTrailingPathSeparator $ fromRelDir rel
      createSymbolicLink to' from'
      pure $! Item outHash
--
-- It is the callers responsibility to ensure that no other threads or processes
-- will attempt to access the subtree afterwards.
removeFailed :: ContentStore -> ContentHash -> IO ()
removeFailed store hash = withStoreLock store $
  internalQuery store hash >>= \case
    Missing () -> throwIO (NotPending hash)
    Complete _ -> throwIO (AlreadyComplete hash)
    Pending build -> withWritableStore store $
      removePathForcibly (fromAbsDir build)

-- | Remove a subtree independent of its state.
-- Do nothing if it doesn't exist.
--
-- It is the callers responsibility to ensure that no other threads or processes
-- will attempt to access the subtree afterwards.
removeForcibly :: ContentStore -> ContentHash -> IO ()
removeForcibly store hash = withStoreLock store $ withWritableStore store $
  internalQuery store hash >>= \case
    Missing () -> pure ()
    Pending build -> removePathForcibly (fromAbsDir build)
    Complete _out ->
      removePathForcibly $
        dropTrailingPathSeparator $ fromAbsDir $ mkCompletePath store hash
      -- XXX: This will leave orphan store items behind.
      --   Add GC in some form.

-- | Remove a completed item in the store.
-- Do nothing if not completed.
--
-- It is the callers responsibility to ensure that no other threads or processes
-- will attempt to access the contents afterwards.
--
-- Note, this will leave keys pointing to that item dangling.
-- There is no garbage collection mechanism in place at the moment.
removeItemForcibly :: ContentStore -> Item -> IO ()
removeItemForcibly store item = withStoreLock store $ withWritableStore store $
  removePathForcibly (fromAbsDir $ itemPath store item)
  -- XXX: Remove dangling links.
  --   Add back-references in some form.

----------------------------------------------------------------------
-- Internals

lockPath :: Path Abs Dir -> Path Abs File
lockPath = (</> [relfile|lock|])

makeLockDesc :: LockRequest -> FileLock
makeLockDesc req = (req, AbsoluteSeek, COff 0, COff 1)

acquireStoreFileLock :: ContentStore -> IO ()
acquireStoreFileLock ContentStore {storeLockFd} = do
  let lockDesc = makeLockDesc WriteLock
  waitToSetLock storeLockFd lockDesc

releaseStoreFileLock :: ContentStore -> IO ()
releaseStoreFileLock ContentStore {storeLockFd} = do
  let lockDesc = makeLockDesc Unlock
  setLock storeLockFd lockDesc

-- | Holds an exclusive write lock on the global lock file
-- for the duration of the given action.
withStoreFileLock :: ContentStore -> IO a -> IO a
withStoreFileLock store =
  bracket_ (acquireStoreFileLock store) (releaseStoreFileLock store)

-- | Holds a lock on the global 'MVar' and on the global lock file
-- for the duration of the given action.
withStoreLock :: ContentStore -> IO a -> IO a
withStoreLock store action =
  withMVar (storeLock store) $ \() ->
    withStoreFileLock store $
      action

prefixHashPath :: C8.ByteString -> ContentHash -> Path Rel Dir
prefixHashPath pref hash
  | Just dir <- Path.parseRelDir $ C8.unpack $ pref <> encodeHash hash
  = dir
  | otherwise = error
      "[Control.FunFlow.ContentStore.prefixHashPath] \
      \Failed to construct hash path."

pendingPrefix, completePrefix, itemPrefix :: IsString s => s
pendingPrefix = "pending-"
completePrefix = "complete-"
itemPrefix = "item-"

-- | Return the full build path for the given input hash.
mkPendingPath :: ContentStore -> ContentHash -> Path Abs Dir
mkPendingPath ContentStore {storeRoot} hash =
  storeRoot </> prefixHashPath pendingPrefix hash

-- | Return the full link path for the given input hash.
mkCompletePath :: ContentStore -> ContentHash -> Path Abs Dir
mkCompletePath ContentStore {storeRoot} hash =
  storeRoot </> prefixHashPath completePrefix hash

-- | Return the full store path to the given output hash.
mkItemPath :: ContentStore -> ContentHash -> Path Abs Dir
mkItemPath ContentStore {storeRoot} hash =
  storeRoot </> prefixHashPath itemPrefix hash

-- | Query the state under the given key without taking a lock.
internalQuery
  :: ContentStore
  -> ContentHash
  -> IO (Status () (Path Abs Dir) Item)
internalQuery store inHash = do
  let build = mkPendingPath store inHash
      link' = mkCompletePath store inHash
  buildExists <- doesDirExist build
  if buildExists then
    pure $! Pending build
  else do
    linkExists <- doesDirExist link'
    if linkExists then do
      out <- readSymbolicLink
        (dropTrailingPathSeparator $ fromAbsDir link')
      case pathToHash =<< stripPrefix itemPrefix out of
        Nothing -> throwIO $ CorruptedLink inHash out
        Just outHash -> return $ Complete (Item outHash)
    else
      pure $! Missing ()

-- | Create the build directory for the given input hash.
createBuildDir :: ContentStore -> ContentHash -> IO (Path Abs Dir)
createBuildDir store hash = do
  let dir = mkPendingPath store hash
  createDir dir
  setDirWritable dir
  return dir

-- | Watch the build directory of the pending item under the given key.
-- The returned 'Async' completes after the item is completed or failed.
internalWatchPending
  :: ContentStore
  -> ContentHash
  -> IO (Async Update)
internalWatchPending store hash = do
  let build = mkPendingPath store hash
  -- Add an inotify watch and give a signal on relevant events.
  let inotify = storeINotify store
      mask = [Attrib, MoveSelf, DeleteSelf, OnlyDir]
  signal <- newEmptyMVar
  -- Signal the listener. If the 'MVar' is full,
  -- the listener didn't handle earlier signals, yet.
  let giveSignal = void $ tryPutMVar signal ()
  watch <- addWatch inotify mask (fromAbsDir build) $ \case
    Attributes True Nothing -> giveSignal
    MovedSelf True -> giveSignal
    DeletedSelf -> giveSignal
    _ -> return ()
  -- Additionally, poll on regular intervals.
  -- Inotify doesn't cover all cases, e.g. network filesystems.
  let tenMinutes = 10 * 60 * 1000000
  ticker <- async $ forever $ threadDelay tenMinutes >> giveSignal
  let stopWatching = do
        cancel ticker
        -- When calling `addWatch` on a path that is already being watched,
        -- inotify will not create a new watch, but amend the existing watch
        -- and return the same watch descriptor.
        -- Therefore, the watch might already have been removed at this point,
        -- which will cause an 'IOError'.
        -- Fortunately, all event handlers to a file are called at once.
        -- So, that removing the watch here will not cause another handler
        -- to miss out on the event.
        -- Note, that this may change when adding different event handlers,
        -- that remove the watch under different conditions.
        removeWatch watch `catch` \(_::IOError) -> return ()
  -- Listen to the signal asynchronously,
  -- and query the status when it fires.
  -- If the status changed, fill in the update.
  update <- newEmptyMVar
  let query' = withStoreLock store $ internalQuery store hash
      loop = takeMVar signal >> query' >>= \case
        Pending _ -> loop
        Complete item -> tryPutMVar update $ Completed item
        Missing () -> tryPutMVar update Failed
  void $ async loop
  -- Wait for the update asynchronously.
  -- Stop watching when it arrives.
  async $ takeMVar update <* stopWatching

setRootDirWritable :: ContentStore -> IO ()
setRootDirWritable ContentStore {storeRoot} =
  setFileMode (fromAbsDir storeRoot) writableRootDirMode

writableRootDirMode :: FileMode
writableRootDirMode = writableDirMode

setRootDirReadOnly :: ContentStore -> IO ()
setRootDirReadOnly ContentStore {storeRoot} =
  setFileMode (fromAbsDir storeRoot) readOnlyRootDirMode

readOnlyRootDirMode :: FileMode
readOnlyRootDirMode = writableDirMode `intersectFileModes` allButWritableMode

withWritableStore :: ContentStore -> IO a -> IO a
withWritableStore store =
  bracket_ (setRootDirWritable store) (setRootDirReadOnly store)

setDirWritable :: Path Abs Dir -> IO ()
setDirWritable fp = setFileMode (fromAbsDir fp) writableDirMode

writableDirMode :: FileMode
writableDirMode = foldl' unionFileModes nullFileMode
  [ directoryMode, ownerModes
  , groupReadMode, groupExecuteMode
  , otherReadMode, otherExecuteMode
  ]

-- | Unset write permissions on the given path.
unsetWritable :: Path Abs t -> IO ()
unsetWritable fp = do
  mode <- fileMode <$> getFileStatus (toFilePath fp)
  setFileMode (toFilePath fp) $ mode `intersectFileModes` allButWritableMode

allButWritableMode :: FileMode
allButWritableMode = complement $ foldl' unionFileModes nullFileMode
  [ownerWriteMode, groupWriteMode, otherWriteMode]

-- | Unset write permissions on all items in a directory tree recursively.
unsetWritableRecursively :: Path Abs Dir -> IO ()
unsetWritableRecursively = walkDir $ \dir _ files -> do
  mapM_ unsetWritable files
  unsetWritable dir
  return $ WalkExclude []
