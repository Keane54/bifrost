// The deny-by-default profile the module host gives sandbox_init before it reads anything. It
// starts from Chromium's common.sb list and keeps only what Foundation and JavaScriptCore need to
// run: system frameworks and data, a few sysctls, logging and the libinfo lookup. Everything else,
// the network, every other file, starting a process and cfprefsd included, stays denied. Apple
// never documented this language, so the check app proves the profile on each macOS we ship to.
package enum SandboxProfile {
    package static let text = """
        (version 1)
        (deny default)

        ; The linked libraries are mapped before sandbox_init runs, but the frameworks still read
        ; their own resources, and JavaScriptCore reads the ICU and locale data.
        (allow file-read*
            (subpath "/System/Library/Frameworks")
            (subpath "/System/Library/PrivateFrameworks")
            (subpath "/usr/lib")
            (subpath "/usr/share/icu")
            (subpath "/usr/share/locale"))

        ; The time zone data, and the links on the way to it.
        (allow file-read*
            (literal "/private/etc/localtime")
            (subpath "/usr/share/zoneinfo")
            (subpath "/usr/share/zoneinfo.default")
            (subpath "/private/var/db/timezone"))
        (allow file-read-metadata
            (literal "/etc")
            (literal "/var"))

        (allow file-read*
            (literal "/dev/random")
            (literal "/dev/urandom")
            (literal "/dev/null"))

        ; Chromium's list, plus hw.pagesize_compat, which getpagesize reads. Without it getpagesize
        ; gives -1 and JavaScriptCore traps as its first context starts, when it remaps its config
        ; page to that size.
        (allow sysctl-read
            (sysctl-name "hw.activecpu")
            (sysctl-name "hw.byteorder")
            (sysctl-name "hw.cpufamily")
            (sysctl-name "hw.memsize")
            (sysctl-name "hw.ncpu")
            (sysctl-name "hw.pagesize_compat")
            (sysctl-name "hw.physicalcpu_max")
            (sysctl-name "kern.hostname")
            (sysctl-name "kern.osrelease")
            (sysctl-name "kern.secure_kernel")
            (sysctl-name "kern.version")
            (sysctl-name "sysctl.proc_cputype")
            (sysctl-name-prefix "hw.optional.")
            (sysctl-name-prefix "hw.perflevel."))

        ; Logging, and the user and group lookups of libinfo. cfprefsd isn't here, so no
        ; preferences reach the host.
        (allow mach-lookup
            (global-name "com.apple.logd")
            (global-name "com.apple.system.opendirectoryd.libinfo"))

        (allow process-info-pidinfo (target self))
        (allow signal (target self))
        """
}
