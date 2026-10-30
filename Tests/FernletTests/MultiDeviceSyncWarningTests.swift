import Testing
import CloudKitSync

struct MultiDeviceSyncWarningTests {
    @Test func syncOnWithAccountNeverWarns() {
        // Sync on with an account → CloudKit keeps the devices merged, so no warning regardless of data.
        #expect(MultiDeviceSyncWarning.classify(iCloudAccountPresent: true, syncEnabled: true, otherDeviceHasData: true) == nil)
        #expect(MultiDeviceSyncWarning.classify(iCloudAccountPresent: true, syncEnabled: true, otherDeviceHasData: false) == nil)
    }

    @Test func syncOnWithoutAccountSaysNothingIsSyncing() {
        // Chosen is not working: with no account the store loads without CloudKit, so the page must say so.
        #expect(
            MultiDeviceSyncWarning.classify(iCloudAccountPresent: false, syncEnabled: true, otherDeviceHasData: false)
                == .syncOnWithoutAccount
        )
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
        for warning in [MultiDeviceSyncWarning.anotherDeviceHasData, .syncOffWithAccount, .noICloudAccount, .syncOnWithoutAccount] {
            #expect(!warning.message.isEmpty)
        }
    }
}
