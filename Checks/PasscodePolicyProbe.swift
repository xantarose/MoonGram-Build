func expectFailure(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Expected a rejected storage configuration") }
    catch PasscodeError.unavailable {}
    catch { fatalError("Unexpected storage policy error") }
}

let group = "group.app.moongram.ios.personal"
let ownGroup = "TESTPREFIX.app.moongram.ios.personal"
var resolutions = 0
let personal = PasscodeEnvironment()
try personal.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .mainApp, storageScope: .applicationOnly), privateAccessGroup: {
    resolutions += 1
    return ownGroup
})
let checkedGroup1 = try personal.sharedAccessGroup()
assert(checkedGroup1 == ownGroup)
let checkedGroup2 = try personal.privateAccessGroup()
assert(checkedGroup2 == ownGroup)
let checkedGroup3 = try personal.sharedAccessGroup()
assert(checkedGroup3 == ownGroup)
assert(resolutions == 1)
expectFailure {
    try personal.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .mainApp), privateAccessGroup: { ownGroup })
}

let regular = PasscodeEnvironment()
try regular.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .mainApp), privateAccessGroup: { ownGroup })
let checkedGroup4 = try regular.sharedAccessGroup()
assert(checkedGroup4 == group)
let checkedGroup5 = try regular.privateAccessGroup()
assert(checkedGroup5 == ownGroup)

let extensionEnvironment = PasscodeEnvironment()
expectFailure {
    try extensionEnvironment.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .appExtension, storageScope: .applicationOnly))
}
try extensionEnvironment.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .appExtension))
let checkedGroup6 = try extensionEnvironment.sharedAccessGroup()
assert(checkedGroup6 == group)
expectFailure { _ = try extensionEnvironment.privateAccessGroup() }

let missingIdentity = PasscodeEnvironment()
expectFailure {
    try missingIdentity.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .mainApp, storageScope: .applicationOnly))
}
print("Passcode storage scope policy passed; no OS keychain operations performed.")
