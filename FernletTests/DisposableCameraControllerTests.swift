import Testing
import FernletDomainModel
@testable import Fernlet

/// Pure state-machine tests for CameraCaptureController — no AVFoundation device required.
/// configureSession() exits early on the simulator (no camera), leaving arm/wind logic intact.
@Suite(.serialized) @MainActor
struct DisposableCameraControllerTests {

    // MARK: - Initial state

    @Test func initialState_isArmed() {
        let camera = CameraCaptureController()
        #expect(camera.isArmed == true, "Camera should start armed so first shot is ready")
    }

    @Test func initialState_windProgressIsZero() {
        let camera = CameraCaptureController()
        #expect(camera.windProgress == 0.0)
    }

    @Test func unconfiguredCaptureThrowsCameraUnavailable() async {
        let camera = CameraCaptureController()

        #expect(camera.canCapturePhoto == false)
        await #expect(throws: CameraCaptureController.CaptureError.cameraUnavailable) {
            _ = try await camera.capturePhoto()
        }
    }

    // MARK: - Disarm

    @Test func disarm_clearsIsArmed() {
        let camera = CameraCaptureController()
        camera.disarm()
        #expect(camera.isArmed == false)
    }

    @Test func disarm_resetsWindProgress() {
        let camera = CameraCaptureController()
        camera.disarm()
        camera.advanceWind(progress: 0.5)   // partial wind after disarm
        camera.disarm()                     // disarm again
        #expect(camera.windProgress == 0.0)
    }

    // MARK: - Wind advances progress

    @Test func advanceWind_setsProgress() {
        let camera = CameraCaptureController()
        camera.disarm()
        camera.advanceWind(progress: 0.4)
        #expect(camera.windProgress == 0.4)
    }

    @Test func advanceWind_clampsAboveOne() {
        let camera = CameraCaptureController()
        camera.disarm()
        camera.advanceWind(progress: 1.5)
        // Progress resets to 0 and isArmed is set on reaching 1.0
        #expect(camera.isArmed == true)
        #expect(camera.windProgress == 0.0, "windProgress should reset to 0 after arming")
    }

    @Test func advanceWind_ignoresBelowZero() {
        let camera = CameraCaptureController()
        camera.disarm()
        camera.advanceWind(progress: -0.5)
        #expect(camera.windProgress == 0.0)
    }

    // MARK: - Arm on full wind

    @Test func advanceWind_armsAtExactlyOne() {
        let camera = CameraCaptureController()
        camera.disarm()
        camera.advanceWind(progress: 1.0)
        #expect(camera.isArmed == true)
    }

    @Test func advanceWind_doesNotArmBelowOne() {
        let camera = CameraCaptureController()
        camera.disarm()
        camera.advanceWind(progress: 0.99)
        #expect(camera.isArmed == false, "Progress below 1.0 must not arm the camera")
    }

    // MARK: - Re-arm cycle

    @Test func rearm_afterDisarm_windThenFire() {
        let camera = CameraCaptureController()
        // First shot
        #expect(camera.isArmed)
        camera.disarm()
        #expect(!camera.isArmed)
        // Wind up
        camera.advanceWind(progress: 1.0)
        #expect(camera.isArmed, "Full wind should re-arm")
    }

    // MARK: - No wind while armed

    @Test func advanceWind_noopWhenAlreadyArmed() {
        let camera = CameraCaptureController()
        // Already armed from init — wind gestures should be ignored
        camera.advanceWind(progress: 0.8)
        #expect(camera.windProgress == 0.0, "Wind progress should not advance when already armed")
        #expect(camera.isArmed == true)
    }

    // MARK: - Reset wind

    @Test func resetWind_clearsProgressWhenDisarmed() {
        let camera = CameraCaptureController()
        camera.disarm()
        camera.advanceWind(progress: 0.6)
        camera.resetWind()
        #expect(camera.windProgress == 0.0)
        #expect(camera.isArmed == false, "resetWind should not arm the camera")
    }

    @Test func resetWind_noopWhenArmed() {
        let camera = CameraCaptureController()
        // Armed from init; resetWind should not change state
        camera.resetWind()
        #expect(camera.isArmed == true)
        #expect(camera.windProgress == 0.0)
    }
}
