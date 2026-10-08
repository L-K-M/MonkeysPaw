#if os(Linux)
import Foundation
import MonkeysPawLinux

// Top-level main.swift enters GLib synchronously. An async @main would drain
// the dispatch main queue in competition with GTK's loop.
exit(MonkeysPawLinuxApp.main())
#endif
