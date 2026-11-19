// A file outside the Reviews module checks a trust run, on one line, over two lines and through
// the init of the enum.
let run = await TrustRuns.check(folder: clone, root: root)
let other = await TrustRuns
    .check(folder: clone, root: root)
let third = await TrustRuns.check (folder: URL(filePath: "/"), root: root)
