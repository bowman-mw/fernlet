import Testing
import CloudKitSync

struct MultiDeviceSyncWarningTests {
    @Test func syncOnNeverWarns() {
        // Sync on → CloudKit keeps the devices merged, so no warning regardless of the other inputs.
        #expect(MultiDeviceSyncWarning.classify(iCloudAccountPresent: true, syncEnabled: true, otherDeviceHasData: true) == nil)
        #expect(MultiDeviceSyncWarning.classify(iCloudAccountPresent: true, syncEnabled: true, otherDeviceHasData: false) == nil)
        #expect(MultiDeviceSyncWarning.classify(iCloudAccountPresent: false, syncEnabled: true, otherDeviceHasData: false) == nil)
    }

    @Test func syncOffWithAccountAndOtherDeviceData() {
        #expect(
            MultiDeviceSyncWarning.classify(iCloudAccountPresent: true, syncEnabled: false, otherDeviceHasData: true)
                == .anotherDeviceHasData
        )
    }

    @Test func syncOffWithAccountNoOtherData() {
        #expect(
            MultiDeviceSyncWarning.classify(iCloudAccountPresent: true, syncEnabled: false, otherDeviceHasData: false)
                == .syncOffWithAccount
        )
    }

    @Test func syncOffNoAccountIsGenericRegardlessOfData() {
        // No account → nothing is detectable; collapse to the generic local-only warning.
        #expect(
            MultiDeviceSyncWarning.classify(iCloudAccountPresent: false, syncEnabled: false, otherDeviceHasData: false)
                == .noICloudAccount
        )
        #expect(
            MultiDeviceSyncWarning.classify(iCloudAccountPresent: false, syncEnabled: false, otherDeviceHasData: true)
                == .noICloudAccount
        )
    }

    @Test func everyCaseHasNonEmptyMessage() {
        for warning in [MultiDeviceSyncWarning.anotherDeviceHasData, .syncOffWithAccount, .noICloudAccount] {
            #expect(!warning.message.isEmpty)
        }
    }
}
