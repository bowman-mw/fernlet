// ExerciseHowTo+Pull.swift
// FernletDomainModel — how-to text for the catalog's upper-body pulls: pull-ups, pulldowns, rows, curls, rear-delt and shrug work.
//
// Fernlet-written, clean-room text (no website, dataset or book was copied or paraphrased),
// awaiting one review by a qualified coach before it ships. Every string is a catalog key under
// `exercise.<keyStem>.` resolved against `.module`; the English default here is what
// Scripts/sync-string-catalogs.sh harvests into Localizable.xcstrings, so edit both together.

import Foundation

extension ExerciseHowToCatalog {
    /// Upper-body pulls: pull-ups, pulldowns, rows, curls, rear-delt and shrug work. In catalog order.
    static var pullEntries: [ExerciseHowTo] {
        [
            pullUp,
            chinUp,
            latPulldown,
            barbellRow,
            dumbbellRow,
            cableRow,
            facePull,
            bicepsCurl,
            hammerCurl,
            preacherCurl,
            rearDeltFly,
            shrug,
            invertedRow,
            bandRow,
            bandLatPulldown,
            bandPullApart,
            bandBicepsCurl,
            dumbbellPullover,
            chestSupportedDumbbellRow,
            seatedRowMachine,
            assistedPullUp,
            bandAssistedPullUp,
            bandFacePull,
            reversePecDeck,
            bandExternalRotation,
            barbellCurl,
        ]
    }

    static var pullUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Pull-up", keyStem: "pullUp",
            displayName: String(localized: "exercise.pullUp.name", defaultValue: "Pull-up",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.pullUp.cue1", defaultValue: "Hang with hands a bit wider than shoulders, palms facing away.",
                       bundle: .module, comment: "Pull-up: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.pullUp.cue2", defaultValue: "Pull your shoulders down and back before you bend your arms.",
                       bundle: .module, comment: "Pull-up: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.pullUp.cue3", defaultValue: "Drive your elbows toward your ribs until your chin clears the bar.",
                       bundle: .module, comment: "Pull-up: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.pullUp.cue4", defaultValue: "Lower all the way to straight arms with control.",
                       bundle: .module, comment: "Pull-up: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.pullUp.mistake", defaultValue: "Kicking or swinging the legs to get the chin over the bar.",
                            bundle: .module, comment: "Pull-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.pullUp.easier", defaultValue: "Use a resistance band or an assisted machine, or do inverted rows.",
                           bundle: .module, comment: "Pull-up: an easier version, as a short instruction")
        )
    }

    static var chinUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Chin-up", keyStem: "chinUp",
            displayName: String(localized: "exercise.chinUp.name", defaultValue: "Chin-up",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.chinUp.cue1", defaultValue: "Hang with hands shoulder-width apart, palms facing you.",
                       bundle: .module, comment: "Chin-up: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.chinUp.cue2", defaultValue: "Brace your stomach and keep your legs still.",
                       bundle: .module, comment: "Chin-up: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.chinUp.cue3", defaultValue: "Pull your chest toward the bar, elbows driving down.",
                       bundle: .module, comment: "Chin-up: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.chinUp.cue4", defaultValue: "Lower slowly until your arms are straight again.",
                       bundle: .module, comment: "Chin-up: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.chinUp.mistake", defaultValue: "Doing half reps that never return to straight arms at the bottom.",
                            bundle: .module, comment: "Chin-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.chinUp.easier", defaultValue: "Jump to the top and lower yourself slowly, or use an assisting band.",
                           bundle: .module, comment: "Chin-up: an easier version, as a short instruction")
        )
    }

    static var latPulldown: ExerciseHowTo {
        ExerciseHowTo(
            name: "Lat pulldown", keyStem: "latPulldown",
            displayName: String(localized: "exercise.latPulldown.name", defaultValue: "Lat pulldown",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.latPulldown.cue1", defaultValue: "Adjust the thigh pad so your legs are held in place.",
                       bundle: .module, comment: "Lat pulldown: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.latPulldown.cue2", defaultValue: "Grip the bar a little wider than your shoulders.",
                       bundle: .module, comment: "Lat pulldown: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.latPulldown.cue3", defaultValue: "Lean back slightly and pull the bar to your upper chest.",
                       bundle: .module, comment: "Lat pulldown: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.latPulldown.cue4", defaultValue: "Squeeze your shoulder blades down, then let the bar rise slowly.",
                       bundle: .module, comment: "Lat pulldown: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.latPulldown.mistake", defaultValue: "Leaning far back and yanking the bar down with the whole body.",
                            bundle: .module, comment: "Lat pulldown: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.latPulldown.easier", defaultValue: "Use a lighter weight, or try a band pulldown.",
                           bundle: .module, comment: "Lat pulldown: an easier version, as a short instruction")
        )
    }

    static var barbellRow: ExerciseHowTo {
        ExerciseHowTo(
            name: "Barbell row", keyStem: "barbellRow",
            displayName: String(localized: "exercise.barbellRow.name", defaultValue: "Barbell row",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.barbellRow.cue1", defaultValue: "Hinge at the hips with a flat back, bar below your shoulders.",
                       bundle: .module, comment: "Barbell row: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.barbellRow.cue2", defaultValue: "Grip just outside your knees and brace your stomach.",
                       bundle: .module, comment: "Barbell row: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.barbellRow.cue3", defaultValue: "Pull the bar to your lower ribs, elbows close to your body.",
                       bundle: .module, comment: "Barbell row: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.barbellRow.cue4", defaultValue: "Lower with control without standing up between reps.",
                       bundle: .module, comment: "Barbell row: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.barbellRow.mistake", defaultValue: "Rounding the back or standing up more each rep to heave the bar.",
                            bundle: .module, comment: "Barbell row: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.barbellRow.easier", defaultValue: "Row a dumbbell with one hand on a bench for support.",
                           bundle: .module, comment: "Barbell row: an easier version, as a short instruction")
        )
    }

    static var dumbbellRow: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell row", keyStem: "dumbbellRow",
            displayName: String(localized: "exercise.dumbbellRow.name", defaultValue: "Dumbbell row",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellRow.cue1", defaultValue: "Put one hand and knee on a bench, back flat.",
                       bundle: .module, comment: "Dumbbell row: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellRow.cue2", defaultValue: "Let the dumbbell hang straight down from your shoulder.",
                       bundle: .module, comment: "Dumbbell row: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellRow.cue3", defaultValue: "Pull it toward your hip, leading with the elbow.",
                       bundle: .module, comment: "Dumbbell row: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellRow.cue4", defaultValue: "Lower slowly until your arm is straight, then switch sides.",
                       bundle: .module, comment: "Dumbbell row: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellRow.mistake", defaultValue: "Twisting the torso open to swing the weight up.",
                            bundle: .module, comment: "Dumbbell row: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellRow.easier", defaultValue: "Use a lighter dumbbell, or lie chest-down on an incline bench to row.",
                           bundle: .module, comment: "Dumbbell row: an easier version, as a short instruction")
        )
    }

    static var cableRow: ExerciseHowTo {
        ExerciseHowTo(
            name: "Cable row", keyStem: "cableRow",
            displayName: String(localized: "exercise.cableRow.name", defaultValue: "Cable row",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.cableRow.cue1", defaultValue: "Sit tall with feet on the platform and knees slightly bent.",
                       bundle: .module, comment: "Cable row: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.cableRow.cue2", defaultValue: "Hold the handle with straight arms and relaxed shoulders.",
                       bundle: .module, comment: "Cable row: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.cableRow.cue3", defaultValue: "Pull the handle to your stomach, squeezing your shoulder blades.",
                       bundle: .module, comment: "Cable row: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.cableRow.cue4", defaultValue: "Keep your torso still as your arms return forward.",
                       bundle: .module, comment: "Cable row: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.cableRow.mistake", defaultValue: "Rocking the torso back and forth to move the weight.",
                            bundle: .module, comment: "Cable row: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.cableRow.easier", defaultValue: "Use a lighter weight, or loop a band around your feet and row.",
                           bundle: .module, comment: "Cable row: an easier version, as a short instruction")
        )
    }

    static var facePull: ExerciseHowTo {
        ExerciseHowTo(
            name: "Face pull", keyStem: "facePull",
            displayName: String(localized: "exercise.facePull.name", defaultValue: "Face pull",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.facePull.cue1", defaultValue: "Set a rope at upper-chest height or a little higher.",
                       bundle: .module, comment: "Face pull: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.facePull.cue2", defaultValue: "Hold the rope ends with your thumbs pointing back toward you.",
                       bundle: .module, comment: "Face pull: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.facePull.cue3", defaultValue: "Pull toward your face, spreading the rope ends apart.",
                       bundle: .module, comment: "Face pull: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.facePull.cue4", defaultValue: "Finish with elbows high and hands beside your ears.",
                       bundle: .module, comment: "Face pull: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.facePull.cue5", defaultValue: "Return slowly with your shoulders staying down.",
                       bundle: .module, comment: "Face pull: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.facePull.mistake", defaultValue: "Using so much weight that you lean back and pull with the lower back.",
                            bundle: .module, comment: "Face pull: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.facePull.easier", defaultValue: "Do band pull-aparts, or use a lighter cable weight.",
                           bundle: .module, comment: "Face pull: an easier version, as a short instruction")
        )
    }

    static var bicepsCurl: ExerciseHowTo {
        ExerciseHowTo(
            name: "Biceps curl", keyStem: "bicepsCurl",
            displayName: String(localized: "exercise.bicepsCurl.name", defaultValue: "Biceps curl",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.bicepsCurl.cue1", defaultValue: "Stand tall with dumbbells at your sides, palms facing forward.",
                       bundle: .module, comment: "Biceps curl: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bicepsCurl.cue2", defaultValue: "Keep your elbows close to your ribs.",
                       bundle: .module, comment: "Biceps curl: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bicepsCurl.cue3", defaultValue: "Curl the weights up without swinging your body.",
                       bundle: .module, comment: "Biceps curl: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bicepsCurl.cue4", defaultValue: "Lower slowly until your arms are straight.",
                       bundle: .module, comment: "Biceps curl: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bicepsCurl.mistake", defaultValue: "Swinging the hips and shoulders to heave the weight up.",
                            bundle: .module, comment: "Biceps curl: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bicepsCurl.easier", defaultValue: "Use lighter dumbbells, or curl one arm at a time while seated.",
                           bundle: .module, comment: "Biceps curl: an easier version, as a short instruction")
        )
    }

    static var hammerCurl: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hammer curl", keyStem: "hammerCurl",
            displayName: String(localized: "exercise.hammerCurl.name", defaultValue: "Hammer curl",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.hammerCurl.cue1", defaultValue: "Hold dumbbells at your sides with palms facing each other.",
                       bundle: .module, comment: "Hammer curl: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.hammerCurl.cue2", defaultValue: "Keep your elbows still and close to your body.",
                       bundle: .module, comment: "Hammer curl: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.hammerCurl.cue3", defaultValue: "Curl up, keeping your thumbs pointing to the ceiling.",
                       bundle: .module, comment: "Hammer curl: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.hammerCurl.cue4", defaultValue: "Lower slowly to straight arms.",
                       bundle: .module, comment: "Hammer curl: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hammerCurl.mistake", defaultValue: "Letting the elbows drift forward so the shoulders take over.",
                            bundle: .module, comment: "Hammer curl: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hammerCurl.easier", defaultValue: "Use lighter dumbbells, or curl one arm at a time.",
                           bundle: .module, comment: "Hammer curl: an easier version, as a short instruction")
        )
    }

    static var preacherCurl: ExerciseHowTo {
        ExerciseHowTo(
            name: "Preacher curl", keyStem: "preacherCurl",
            displayName: String(localized: "exercise.preacherCurl.name", defaultValue: "Preacher curl",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.preacherCurl.cue1", defaultValue: "Set the seat so your upper arms rest flat on the pad.",
                       bundle: .module, comment: "Preacher curl: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.preacherCurl.cue2", defaultValue: "Hold the handles with your palms facing up.",
                       bundle: .module, comment: "Preacher curl: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.preacherCurl.cue3", defaultValue: "Curl up smoothly and pause near the top.",
                       bundle: .module, comment: "Preacher curl: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.preacherCurl.cue4", defaultValue: "Lower slowly, stopping just short of locking your elbows.",
                       bundle: .module, comment: "Preacher curl: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.preacherCurl.mistake", defaultValue: "Dropping fast into the bottom and jolting the straightened elbows.",
                            bundle: .module, comment: "Preacher curl: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.preacherCurl.easier", defaultValue: "Use a lighter weight and stop a little higher at the bottom.",
                           bundle: .module, comment: "Preacher curl: an easier version, as a short instruction")
        )
    }

    static var rearDeltFly: ExerciseHowTo {
        ExerciseHowTo(
            name: "Rear delt fly", keyStem: "rearDeltFly",
            displayName: String(localized: "exercise.rearDeltFly.name", defaultValue: "Rear delt fly",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.rearDeltFly.cue1", defaultValue: "Hinge forward with a flat back, light dumbbells hanging down.",
                       bundle: .module, comment: "Rear delt fly: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.rearDeltFly.cue2", defaultValue: "Keep a soft bend in your elbows.",
                       bundle: .module, comment: "Rear delt fly: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.rearDeltFly.cue3", defaultValue: "Raise your arms out to the sides, leading with the elbows.",
                       bundle: .module, comment: "Rear delt fly: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.rearDeltFly.cue4", defaultValue: "Squeeze between your shoulder blades, then lower slowly.",
                       bundle: .module, comment: "Rear delt fly: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.rearDeltFly.mistake", defaultValue: "Shrugging up or swinging the body to move weights that are too heavy.",
                            bundle: .module, comment: "Rear delt fly: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.rearDeltFly.easier", defaultValue: "Lie chest-down on an incline bench, or do band pull-aparts.",
                           bundle: .module, comment: "Rear delt fly: an easier version, as a short instruction")
        )
    }

    static var shrug: ExerciseHowTo {
        ExerciseHowTo(
            name: "Shrug", keyStem: "shrug",
            displayName: String(localized: "exercise.shrug.name", defaultValue: "Shrug",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.shrug.cue1", defaultValue: "Stand tall holding dumbbells at your sides.",
                       bundle: .module, comment: "Shrug: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.shrug.cue2", defaultValue: "Lift your shoulders straight up toward your ears.",
                       bundle: .module, comment: "Shrug: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.shrug.cue3", defaultValue: "Pause for a moment at the top.",
                       bundle: .module, comment: "Shrug: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.shrug.cue4", defaultValue: "Lower slowly all the way down.",
                       bundle: .module, comment: "Shrug: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.shrug.mistake", defaultValue: "Rolling the shoulders in circles instead of moving straight up and down.",
                            bundle: .module, comment: "Shrug: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.shrug.easier", defaultValue: "Use lighter dumbbells, or shrug with a band under your feet.",
                           bundle: .module, comment: "Shrug: an easier version, as a short instruction")
        )
    }

    static var invertedRow: ExerciseHowTo {
        ExerciseHowTo(
            name: "Inverted row", keyStem: "invertedRow",
            displayName: String(localized: "exercise.invertedRow.name", defaultValue: "Inverted row",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.invertedRow.cue1", defaultValue: "Lie under a bar set at about waist height.",
                       bundle: .module, comment: "Inverted row: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.invertedRow.cue2", defaultValue: "Grip it a little wider than your shoulders.",
                       bundle: .module, comment: "Inverted row: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.invertedRow.cue3", defaultValue: "Keep your body straight from heels to head.",
                       bundle: .module, comment: "Inverted row: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.invertedRow.cue4", defaultValue: "Pull your chest to the bar, squeezing your shoulder blades.",
                       bundle: .module, comment: "Inverted row: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.invertedRow.cue5", defaultValue: "Lower slowly until your arms are straight.",
                       bundle: .module, comment: "Inverted row: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.invertedRow.mistake", defaultValue: "Letting the hips sag so the chest never reaches the bar.",
                            bundle: .module, comment: "Inverted row: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.invertedRow.easier", defaultValue: "Raise the bar higher, or bend your knees with your feet flat.",
                           bundle: .module, comment: "Inverted row: an easier version, as a short instruction")
        )
    }

    static var bandRow: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band row", keyStem: "bandRow",
            displayName: String(localized: "exercise.bandRow.name", defaultValue: "Band row",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandRow.cue1", defaultValue: "Anchor the band at chest height and step back.",
                       bundle: .module, comment: "Band row: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandRow.cue2", defaultValue: "Hold a handle in each hand, arms straight.",
                       bundle: .module, comment: "Band row: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandRow.cue3", defaultValue: "Pull your elbows back past your ribs.",
                       bundle: .module, comment: "Band row: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandRow.cue4", defaultValue: "Squeeze your shoulder blades, then let your arms return slowly.",
                       bundle: .module, comment: "Band row: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandRow.mistake", defaultValue: "Leaning back to pull instead of moving the shoulder blades.",
                            bundle: .module, comment: "Band row: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandRow.easier", defaultValue: "Use a lighter band, or step closer to the anchor.",
                           bundle: .module, comment: "Band row: an easier version, as a short instruction")
        )
    }

    static var bandLatPulldown: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band lat pulldown", keyStem: "bandLatPulldown",
            displayName: String(localized: "exercise.bandLatPulldown.name", defaultValue: "Band lat pulldown",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandLatPulldown.cue1", defaultValue: "Anchor the band high, above a door or bar.",
                       bundle: .module, comment: "Band lat pulldown: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandLatPulldown.cue2", defaultValue: "Kneel or sit facing it, arms reaching up.",
                       bundle: .module, comment: "Band lat pulldown: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandLatPulldown.cue3", defaultValue: "Pull your elbows down toward your ribs.",
                       bundle: .module, comment: "Band lat pulldown: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandLatPulldown.cue4", defaultValue: "Return slowly with your shoulders staying down.",
                       bundle: .module, comment: "Band lat pulldown: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandLatPulldown.mistake", defaultValue: "Shrugging the shoulders up toward the ears as you pull.",
                            bundle: .module, comment: "Band lat pulldown: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandLatPulldown.easier", defaultValue: "Use a lighter band, or move closer to the anchor.",
                           bundle: .module, comment: "Band lat pulldown: an easier version, as a short instruction")
        )
    }

    static var bandPullApart: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band pull-apart", keyStem: "bandPullApart",
            displayName: String(localized: "exercise.bandPullApart.name", defaultValue: "Band pull-apart",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandPullApart.cue1", defaultValue: "Hold a band in front of your chest, hands shoulder-width apart.",
                       bundle: .module, comment: "Band pull-apart: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandPullApart.cue2", defaultValue: "Keep your arms almost straight.",
                       bundle: .module, comment: "Band pull-apart: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandPullApart.cue3", defaultValue: "Pull the band apart until it touches your chest.",
                       bundle: .module, comment: "Band pull-apart: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandPullApart.cue4", defaultValue: "Return slowly without letting the band snap back.",
                       bundle: .module, comment: "Band pull-apart: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandPullApart.mistake", defaultValue: "Shrugging the shoulders or bending the elbows to make it easier.",
                            bundle: .module, comment: "Band pull-apart: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandPullApart.easier", defaultValue: "Use a lighter band, or hold it with your hands wider apart.",
                           bundle: .module, comment: "Band pull-apart: an easier version, as a short instruction")
        )
    }

    static var bandBicepsCurl: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band biceps curl", keyStem: "bandBicepsCurl",
            displayName: String(localized: "exercise.bandBicepsCurl.name", defaultValue: "Band biceps curl",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandBicepsCurl.cue1", defaultValue: "Stand on the band with a handle in each hand.",
                       bundle: .module, comment: "Band biceps curl: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandBicepsCurl.cue2", defaultValue: "Keep your elbows close to your ribs.",
                       bundle: .module, comment: "Band biceps curl: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandBicepsCurl.cue3", defaultValue: "Curl your hands toward your shoulders.",
                       bundle: .module, comment: "Band biceps curl: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandBicepsCurl.cue4", defaultValue: "Lower slowly against the pull of the band.",
                       bundle: .module, comment: "Band biceps curl: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandBicepsCurl.mistake", defaultValue: "Swinging the body and letting the band yank the arms down.",
                            bundle: .module, comment: "Band biceps curl: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandBicepsCurl.easier", defaultValue: "Use a lighter band, or stand on it with one foot.",
                           bundle: .module, comment: "Band biceps curl: an easier version, as a short instruction")
        )
    }

    static var dumbbellPullover: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell pullover", keyStem: "dumbbellPullover",
            displayName: String(localized: "exercise.dumbbellPullover.name", defaultValue: "Dumbbell pullover",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellPullover.cue1", defaultValue: "Lie on a bench, holding one dumbbell above your chest.",
                       bundle: .module, comment: "Dumbbell pullover: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellPullover.cue2", defaultValue: "Hold it with both hands, elbows slightly bent.",
                       bundle: .module, comment: "Dumbbell pullover: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellPullover.cue3", defaultValue: "Lower it back over your head with control.",
                       bundle: .module, comment: "Dumbbell pullover: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellPullover.cue4", defaultValue: "Stop where your shoulders feel a comfortable stretch.",
                       bundle: .module, comment: "Dumbbell pullover: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellPullover.cue5", defaultValue: "Pull it back over your chest.",
                       bundle: .module, comment: "Dumbbell pullover: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellPullover.mistake", defaultValue: "Lowering too far behind the head and arching the back.",
                            bundle: .module, comment: "Dumbbell pullover: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellPullover.easier", defaultValue: "Use a lighter dumbbell and a shorter range.",
                           bundle: .module, comment: "Dumbbell pullover: an easier version, as a short instruction")
        )
    }

    static var chestSupportedDumbbellRow: ExerciseHowTo {
        ExerciseHowTo(
            name: "Chest-supported dumbbell row", keyStem: "chestSupportedDumbbellRow",
            displayName: String(localized: "exercise.chestSupportedDumbbellRow.name", defaultValue: "Chest-supported dumbbell row",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.chestSupportedDumbbellRow.cue1", defaultValue: "Lie chest-down on a bench set to a low incline.",
                       bundle: .module, comment: "Chest-supported dumbbell row: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.chestSupportedDumbbellRow.cue2", defaultValue: "Let the dumbbells hang straight down, palms facing in.",
                       bundle: .module, comment: "Chest-supported dumbbell row: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.chestSupportedDumbbellRow.cue3", defaultValue: "Pull your elbows back until they pass your ribs.",
                       bundle: .module, comment: "Chest-supported dumbbell row: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.chestSupportedDumbbellRow.cue4", defaultValue: "Squeeze your shoulder blades, then lower slowly to straight arms.",
                       bundle: .module, comment: "Chest-supported dumbbell row: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.chestSupportedDumbbellRow.mistake", defaultValue: "Lifting the chest off the bench to heave the weights up.",
                            bundle: .module, comment: "Chest-supported dumbbell row: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.chestSupportedDumbbellRow.easier", defaultValue: "Use lighter dumbbells, or do the band row.",
                           bundle: .module, comment: "Chest-supported dumbbell row: an easier version, as a short instruction")
        )
    }

    static var seatedRowMachine: ExerciseHowTo {
        ExerciseHowTo(
            name: "Seated row machine", keyStem: "seatedRowMachine",
            displayName: String(localized: "exercise.seatedRowMachine.name", defaultValue: "Seated row machine",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.seatedRowMachine.cue1", defaultValue: "Set the seat so the handles are at mid-chest height.",
                       bundle: .module, comment: "Seated row machine: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.seatedRowMachine.cue2", defaultValue: "Adjust the chest pad so you can just reach the handles.",
                       bundle: .module, comment: "Seated row machine: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.seatedRowMachine.cue3", defaultValue: "Sit tall against the pad and pull your elbows back.",
                       bundle: .module, comment: "Seated row machine: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.seatedRowMachine.cue4", defaultValue: "Squeeze your shoulder blades, then let your arms return slowly.",
                       bundle: .module, comment: "Seated row machine: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.seatedRowMachine.mistake", defaultValue: "Rocking back off the chest pad to yank the handles.",
                            bundle: .module, comment: "Seated row machine: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.seatedRowMachine.easier", defaultValue: "Use a lighter weight, or do the band row.",
                           bundle: .module, comment: "Seated row machine: an easier version, as a short instruction")
        )
    }

    static var assistedPullUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Assisted pull-up", keyStem: "assistedPullUp",
            displayName: String(localized: "exercise.assistedPullUp.name", defaultValue: "Assisted pull-up",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.assistedPullUp.cue1", defaultValue: "Set the assistance: more weight on the stack means more help.",
                       bundle: .module, comment: "Assisted pull-up: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.assistedPullUp.cue2", defaultValue: "Grip the handles, then kneel or stand on the pad.",
                       bundle: .module, comment: "Assisted pull-up: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.assistedPullUp.cue3", defaultValue: "Pull your elbows down until your chin is above your hands.",
                       bundle: .module, comment: "Assisted pull-up: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.assistedPullUp.cue4", defaultValue: "Lower slowly until your arms are straight.",
                       bundle: .module, comment: "Assisted pull-up: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.assistedPullUp.mistake", defaultValue: "Dropping fast to the bottom and letting the pad bounce you up.",
                            bundle: .module, comment: "Assisted pull-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.assistedPullUp.easier", defaultValue: "Add more assistance weight so the machine helps you more.",
                           bundle: .module, comment: "Assisted pull-up: an easier version, as a short instruction")
        )
    }

    static var bandAssistedPullUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band-assisted pull-up", keyStem: "bandAssistedPullUp",
            displayName: String(localized: "exercise.bandAssistedPullUp.name", defaultValue: "Band-assisted pull-up",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandAssistedPullUp.cue1", defaultValue: "Anchor the band securely around the bar so it cannot slip.",
                       bundle: .module, comment: "Band-assisted pull-up: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.bandAssistedPullUp.cue2", defaultValue: "Place one knee or foot in the bottom of the loop.",
                       bundle: .module, comment: "Band-assisted pull-up: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.bandAssistedPullUp.cue3", defaultValue: "Hang with straight arms, hands a bit wider than shoulders.",
                       bundle: .module, comment: "Band-assisted pull-up: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.bandAssistedPullUp.cue4", defaultValue: "Pull your elbows down until your chin clears the bar.",
                       bundle: .module, comment: "Band-assisted pull-up: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.bandAssistedPullUp.cue5", defaultValue: "Lower slowly to straight arms, staying steady in the loop.",
                       bundle: .module, comment: "Band-assisted pull-up: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandAssistedPullUp.mistake", defaultValue: "Bouncing out of the bottom so the band does all the work.",
                            bundle: .module, comment: "Band-assisted pull-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandAssistedPullUp.easier", defaultValue: "Use a thicker band for more help, or do inverted rows.",
                           bundle: .module, comment: "Band-assisted pull-up: an easier version, as a short instruction")
        )
    }

    static var bandFacePull: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band face pull", keyStem: "bandFacePull",
            displayName: String(localized: "exercise.bandFacePull.name", defaultValue: "Band face pull",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandFacePull.cue1", defaultValue: "Anchor the band securely at about face height.",
                       bundle: .module, comment: "Band face pull: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.bandFacePull.cue2", defaultValue: "Hold an end in each hand, thumbs pointing back toward you.",
                       bundle: .module, comment: "Band face pull: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.bandFacePull.cue3", defaultValue: "Pull toward your face, spreading your hands apart.",
                       bundle: .module, comment: "Band face pull: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.bandFacePull.cue4", defaultValue: "Pause with your hands beside your ears, elbows high.",
                       bundle: .module, comment: "Band face pull: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.bandFacePull.cue5", defaultValue: "Return slowly without letting the band snap forward.",
                       bundle: .module, comment: "Band face pull: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandFacePull.mistake", defaultValue: "Letting the elbows drop so it turns into a row.",
                            bundle: .module, comment: "Band face pull: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandFacePull.easier", defaultValue: "Use a lighter band, or do band pull-aparts.",
                           bundle: .module, comment: "Band face pull: an easier version, as a short instruction")
        )
    }

    static var reversePecDeck: ExerciseHowTo {
        ExerciseHowTo(
            name: "Reverse pec deck", keyStem: "reversePecDeck",
            displayName: String(localized: "exercise.reversePecDeck.name", defaultValue: "Reverse pec deck",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.reversePecDeck.cue1", defaultValue: "Set the seat so the handles are at shoulder height.",
                       bundle: .module, comment: "Reverse pec deck: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.reversePecDeck.cue2", defaultValue: "Sit facing the pad, chest resting against it.",
                       bundle: .module, comment: "Reverse pec deck: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.reversePecDeck.cue3", defaultValue: "Hold the handles with a soft bend in your elbows.",
                       bundle: .module, comment: "Reverse pec deck: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.reversePecDeck.cue4", defaultValue: "Sweep your arms out and back to about shoulder level.",
                       bundle: .module, comment: "Reverse pec deck: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.reversePecDeck.cue5", defaultValue: "Pause, then let the handles return slowly.",
                       bundle: .module, comment: "Reverse pec deck: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.reversePecDeck.mistake", defaultValue: "Shrugging up and rocking the body to move a weight that is too heavy.",
                            bundle: .module, comment: "Reverse pec deck: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.reversePecDeck.easier", defaultValue: "Use a lighter weight, or do band pull-aparts.",
                           bundle: .module, comment: "Reverse pec deck: an easier version, as a short instruction")
        )
    }

    static var bandExternalRotation: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band external rotation", keyStem: "bandExternalRotation",
            displayName: String(localized: "exercise.bandExternalRotation.name", defaultValue: "Band external rotation",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandExternalRotation.cue1", defaultValue: "Anchor the band securely at elbow height beside you.",
                       bundle: .module, comment: "Band external rotation: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.bandExternalRotation.cue2", defaultValue: "Stand side-on, holding the band in your far hand.",
                       bundle: .module, comment: "Band external rotation: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.bandExternalRotation.cue3", defaultValue: "Bend your elbow at a right angle, tucked against your side.",
                       bundle: .module, comment: "Band external rotation: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.bandExternalRotation.cue4", defaultValue: "Rotate your forearm outward, keeping your elbow in place.",
                       bundle: .module, comment: "Band external rotation: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.bandExternalRotation.cue5", defaultValue: "Return slowly, then switch sides.",
                       bundle: .module, comment: "Band external rotation: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandExternalRotation.mistake", defaultValue: "Letting the elbow drift away from your side as you turn.",
                            bundle: .module, comment: "Band external rotation: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandExternalRotation.easier", defaultValue: "Use a lighter band and a smaller turn.",
                           bundle: .module, comment: "Band external rotation: an easier version, as a short instruction")
        )
    }

    static var barbellCurl: ExerciseHowTo {
        ExerciseHowTo(
            name: "Barbell curl", keyStem: "barbellCurl",
            displayName: String(localized: "exercise.barbellCurl.name", defaultValue: "Barbell curl",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.barbellCurl.cue1", defaultValue: "Stand tall, gripping the bar shoulder-width apart, palms facing forward.",
                       bundle: .module, comment: "Barbell curl: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.barbellCurl.cue2", defaultValue: "Keep your elbows close to your sides.",
                       bundle: .module, comment: "Barbell curl: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.barbellCurl.cue3", defaultValue: "Curl the bar toward your shoulders without leaning back.",
                       bundle: .module, comment: "Barbell curl: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.barbellCurl.cue4", defaultValue: "Lower slowly until your arms are straight.",
                       bundle: .module, comment: "Barbell curl: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.barbellCurl.mistake", defaultValue: "Leaning back and swinging the hips to lift the bar.",
                            bundle: .module, comment: "Barbell curl: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.barbellCurl.easier", defaultValue: "Use just the empty bar, or do biceps curls with dumbbells.",
                           bundle: .module, comment: "Barbell curl: an easier version, as a short instruction")
        )
    }
}
