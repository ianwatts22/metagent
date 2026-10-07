#if !canImport(CoreServices)
// Linux has no FSEvents. These mirror the CoreServices flag values so the
// usage-catalog invalidation state machine compiles and can be unit tested
// unchanged; the Linux catalog watcher itself never starts, which makes every
// refresh run full discovery instead of reusing a cached catalog.

typealias FSEventStreamEventFlags = UInt32
typealias FSEventStreamEventId = UInt64

let kFSEventStreamEventIdSinceNow: UInt64 = 0xFFFF_FFFF_FFFF_FFFF

let kFSEventStreamEventFlagNone = 0x0000_0000
let kFSEventStreamEventFlagMustScanSubDirs = 0x0000_0001
let kFSEventStreamEventFlagUserDropped = 0x0000_0002
let kFSEventStreamEventFlagKernelDropped = 0x0000_0004
let kFSEventStreamEventFlagEventIdsWrapped = 0x0000_0008
let kFSEventStreamEventFlagHistoryDone = 0x0000_0010
let kFSEventStreamEventFlagRootChanged = 0x0000_0020
let kFSEventStreamEventFlagMount = 0x0000_0040
let kFSEventStreamEventFlagUnmount = 0x0000_0080
let kFSEventStreamEventFlagItemCreated = 0x0000_0100
let kFSEventStreamEventFlagItemRemoved = 0x0000_0200
let kFSEventStreamEventFlagItemInodeMetaMod = 0x0000_0400
let kFSEventStreamEventFlagItemRenamed = 0x0000_0800
let kFSEventStreamEventFlagItemModified = 0x0000_1000
let kFSEventStreamEventFlagItemFinderInfoMod = 0x0000_2000
let kFSEventStreamEventFlagItemChangeOwner = 0x0000_4000
let kFSEventStreamEventFlagItemXattrMod = 0x0000_8000
let kFSEventStreamEventFlagItemIsFile = 0x0001_0000
let kFSEventStreamEventFlagItemIsDir = 0x0002_0000
let kFSEventStreamEventFlagItemIsSymlink = 0x0004_0000
let kFSEventStreamEventFlagItemIsHardlink = 0x0010_0000
let kFSEventStreamEventFlagItemCloned = 0x0040_0000

/// There is no system-wide event counter to capture; zero means "no baseline".
func FSEventsGetCurrentEventId() -> FSEventStreamEventId { 0 }
#endif
