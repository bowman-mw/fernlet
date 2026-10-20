// ExerciseHowTo+Push.swift
// FernletDomainModel — how-to text for the catalog's upper-body pushes: presses, push-ups, dips, flys, raises and triceps work.
//
// Fernlet-written, clean-room text (no website, dataset or book was copied or paraphrased),
// awaiting one review by a qualified coach before it ships. Every string is a catalog key under
// `exercise.<keyStem>.` resolved against `.module`; the English default here is what
// Scripts/sync-string-catalogs.sh harvests into Localizable.xcstrings, so edit both together.

import Foundation

extension ExerciseHowToCatalog {
    /// Upper-body pushes: presses, push-ups, dips, flys, raises and triceps work. In catalog order.
    static var pushEntries: [ExerciseHowTo] {
        [
            benchPress,
            inclineBenchPress,
            overheadPress,
            dumbbellBenchPress,
            pushUp,
            dip,
            cableFly,
            lateralRaise,
            frontRaise,
            tricepsPushdown,
            skullcrusher,
            closeGripBench,
            pikePushUp,
            bandChestPress,
            bandOverheadPress,
            bandTricepsPushdown,
            bandLateralRaise,
            dumbbellShoulderPress,
            arnoldPress,
            inclineDumbbellPress,
            dumbbellFloorPress,
            inclinePushUp,
            dumbbellFly,
        ]
    }

    static var benchPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Bench press", keyStem: "benchPress",
            displayName: String(localized: "exercise.benchPress.name", defaultValue: "Bench press",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.benchPress.cue1", defaultValue: "Set the safety arms, or have someone spot you.",
                       bundle: .module, comment: "Bench press: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.benchPress.cue2", defaultValue: "Lie with your eyes under the bar and feet flat.",
                       bundle: .module, comment: "Bench press: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.benchPress.cue3", defaultValue: "Grip the bar a little wider than your shoulders.",
                       bundle: .module, comment: "Bench press: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.benchPress.cue4", defaultValue: "Lower the bar with control to your lower chest.",
                       bundle: .module, comment: "Bench press: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.benchPress.cue5", defaultValue: "Press up until your arms are straight, shoulder blades pinned.",
                       bundle: .module, comment: "Bench press: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.benchPress.mistake", defaultValue: "Bouncing the bar off your chest instead of lowering it under control.",
                            bundle: .module, comment: "Bench press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.benchPress.easier", defaultValue: "Press a pair of light dumbbells, or start with just the empty bar.",
                           bundle: .module, comment: "Bench press: an easier version, as a short instruction")
        )
    }

    static var inclineBenchPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Incline bench press", keyStem: "inclineBenchPress",
            displayName: String(localized: "exercise.inclineBenchPress.name", defaultValue: "Incline bench press",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.inclineBenchPress.cue1", defaultValue: "Set the bench to a low incline, not too upright.",
                       bundle: .module, comment: "Incline bench press: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.inclineBenchPress.cue2", defaultValue: "Plant your feet and pull your shoulder blades together.",
                       bundle: .module, comment: "Incline bench press: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.inclineBenchPress.cue3", defaultValue: "Lower the bar slowly to your upper chest.",
                       bundle: .module, comment: "Incline bench press: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.inclineBenchPress.cue4", defaultValue: "Press up and slightly back over your shoulders.",
                       bundle: .module, comment: "Incline bench press: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.inclineBenchPress.cue5", defaultValue: "Use the safety arms or a spotter for heavier sets.",
                       bundle: .module, comment: "Incline bench press: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.inclineBenchPress.mistake", defaultValue: "Setting the bench so steep that it turns into a shoulder press.",
                            bundle: .module, comment: "Incline bench press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.inclineBenchPress.easier", defaultValue: "Press light dumbbells on the same incline instead of the bar.",
                           bundle: .module, comment: "Incline bench press: an easier version, as a short instruction")
        )
    }

    static var overheadPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Overhead press", keyStem: "overheadPress",
            displayName: String(localized: "exercise.overheadPress.name", defaultValue: "Overhead press",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.overheadPress.cue1", defaultValue: "Stand with feet hip-width apart, bar resting on your front shoulders.",
                       bundle: .module, comment: "Overhead press: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.overheadPress.cue2", defaultValue: "Grip just outside your shoulders, elbows slightly in front of the bar.",
                       bundle: .module, comment: "Overhead press: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.overheadPress.cue3", defaultValue: "Squeeze your glutes and brace your stomach before each rep.",
                       bundle: .module, comment: "Overhead press: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.overheadPress.cue4", defaultValue: "Press straight up, moving your head back to let the bar pass.",
                       bundle: .module, comment: "Overhead press: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.overheadPress.cue5", defaultValue: "Finish with the bar over your mid-foot and arms straight.",
                       bundle: .module, comment: "Overhead press: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.overheadPress.mistake", defaultValue: "Leaning back and arching the lower back to push the bar up.",
                            bundle: .module, comment: "Overhead press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.overheadPress.easier", defaultValue: "Press light dumbbells while seated with your back supported.",
                           bundle: .module, comment: "Overhead press: an easier version, as a short instruction")
        )
    }

    static var dumbbellBenchPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell bench press", keyStem: "dumbbellBenchPress",
            displayName: String(localized: "exercise.dumbbellBenchPress.name", defaultValue: "Dumbbell bench press",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellBenchPress.cue1", defaultValue: "Sit with the dumbbells on your thighs, then lie back with them.",
                       bundle: .module, comment: "Dumbbell bench press: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellBenchPress.cue2", defaultValue: "Start with the weights over your chest, palms facing your feet.",
                       bundle: .module, comment: "Dumbbell bench press: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellBenchPress.cue3", defaultValue: "Lower slowly until your elbows are a little below the bench.",
                       bundle: .module, comment: "Dumbbell bench press: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellBenchPress.cue4", defaultValue: "Keep your elbows angled slightly in, not straight out.",
                       bundle: .module, comment: "Dumbbell bench press: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellBenchPress.cue5", defaultValue: "Press up and in until the dumbbells nearly touch.",
                       bundle: .module, comment: "Dumbbell bench press: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellBenchPress.mistake", defaultValue: "Dropping the dumbbells too low and letting the elbows flare out wide.",
                            bundle: .module, comment: "Dumbbell bench press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellBenchPress.easier", defaultValue: "Use lighter dumbbells, or press from the floor to shorten the range.",
                           bundle: .module, comment: "Dumbbell bench press: an easier version, as a short instruction")
        )
    }

    static var pushUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Push-up", keyStem: "pushUp",
            displayName: String(localized: "exercise.pushUp.name", defaultValue: "Push-up",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.pushUp.cue1", defaultValue: "Place your hands slightly wider than your shoulders.",
                       bundle: .module, comment: "Push-up: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.pushUp.cue2", defaultValue: "Make a straight line from head to heels, stomach braced.",
                       bundle: .module, comment: "Push-up: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.pushUp.cue3", defaultValue: "Lower your chest toward the floor, elbows angled back slightly.",
                       bundle: .module, comment: "Push-up: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.pushUp.cue4", defaultValue: "Push the floor away until your arms are straight.",
                       bundle: .module, comment: "Push-up: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.pushUp.mistake", defaultValue: "Letting the hips sag or pike up so the body is no longer one line.",
                            bundle: .module, comment: "Push-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.pushUp.easier", defaultValue: "Do incline push-ups with your hands on a bench, table or wall.",
                           bundle: .module, comment: "Push-up: an easier version, as a short instruction")
        )
    }

    static var dip: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dip", keyStem: "dip",
            displayName: String(localized: "exercise.dip.name", defaultValue: "Dip",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.dip.cue1", defaultValue: "Hold the bars with straight arms, shoulders pressed down.",
                       bundle: .module, comment: "Dip: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.dip.cue2", defaultValue: "Lean forward a little and keep your elbows tucked back.",
                       bundle: .module, comment: "Dip: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.dip.cue3", defaultValue: "Lower slowly until your upper arms are about parallel to the floor.",
                       bundle: .module, comment: "Dip: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.dip.cue4", defaultValue: "Only go as deep as your shoulders feel comfortable.",
                       bundle: .module, comment: "Dip: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.dip.cue5", defaultValue: "Press back up to straight arms without swinging your legs.",
                       bundle: .module, comment: "Dip: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dip.mistake", defaultValue: "Sinking too deep and letting the shoulders roll forward at the bottom.",
                            bundle: .module, comment: "Dip: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dip.easier", defaultValue: "Use an assisted dip machine, or do close-grip push-ups instead.",
                           bundle: .module, comment: "Dip: an easier version, as a short instruction")
        )
    }

    static var cableFly: ExerciseHowTo {
        ExerciseHowTo(
            name: "Cable fly", keyStem: "cableFly",
            displayName: String(localized: "exercise.cableFly.name", defaultValue: "Cable fly",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.cableFly.cue1", defaultValue: "Set both pulleys near shoulder height and take a handle each.",
                       bundle: .module, comment: "Cable fly: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.cableFly.cue2", defaultValue: "Step forward into a split stance with a slight lean.",
                       bundle: .module, comment: "Cable fly: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.cableFly.cue3", defaultValue: "Keep a soft bend in your elbows the whole time.",
                       bundle: .module, comment: "Cable fly: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.cableFly.cue4", defaultValue: "Bring your hands together in a wide hugging arc.",
                       bundle: .module, comment: "Cable fly: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.cableFly.cue5", defaultValue: "Return slowly until you feel a light stretch across your chest.",
                       bundle: .module, comment: "Cable fly: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.cableFly.mistake", defaultValue: "Bending the elbows more and more until the fly turns into a press.",
                            bundle: .module, comment: "Cable fly: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.cableFly.easier", defaultValue: "Use a lighter weight and a shorter range of motion.",
                           bundle: .module, comment: "Cable fly: an easier version, as a short instruction")
        )
    }

    static var lateralRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Lateral raise", keyStem: "lateralRaise",
            displayName: String(localized: "exercise.lateralRaise.name", defaultValue: "Lateral raise",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.lateralRaise.cue1", defaultValue: "Stand tall with light dumbbells at your sides, palms facing in.",
                       bundle: .module, comment: "Lateral raise: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.lateralRaise.cue2", defaultValue: "Raise your arms out to the sides with a slight elbow bend.",
                       bundle: .module, comment: "Lateral raise: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.lateralRaise.cue3", defaultValue: "Lead with your elbows and stop at about shoulder height.",
                       bundle: .module, comment: "Lateral raise: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.lateralRaise.cue4", defaultValue: "Lower slowly over two or three seconds.",
                       bundle: .module, comment: "Lateral raise: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.lateralRaise.mistake", defaultValue: "Swinging the body or shrugging the shoulders to lift a weight that is too heavy.",
                            bundle: .module, comment: "Lateral raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.lateralRaise.easier", defaultValue: "Use lighter dumbbells, or raise one arm at a time while holding a support.",
                           bundle: .module, comment: "Lateral raise: an easier version, as a short instruction")
        )
    }

    static var frontRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Front raise", keyStem: "frontRaise",
            displayName: String(localized: "exercise.frontRaise.name", defaultValue: "Front raise",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.frontRaise.cue1", defaultValue: "Stand tall with dumbbells in front of your thighs.",
                       bundle: .module, comment: "Front raise: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.frontRaise.cue2", defaultValue: "Brace your stomach and keep your knees soft.",
                       bundle: .module, comment: "Front raise: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.frontRaise.cue3", defaultValue: "Raise the weights forward to about shoulder height.",
                       bundle: .module, comment: "Front raise: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.frontRaise.cue4", defaultValue: "Keep a slight bend in your elbows.",
                       bundle: .module, comment: "Front raise: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.frontRaise.cue5", defaultValue: "Lower slowly without letting the weights swing.",
                       bundle: .module, comment: "Front raise: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.frontRaise.mistake", defaultValue: "Leaning back and using momentum to swing the weights up.",
                            bundle: .module, comment: "Front raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.frontRaise.easier", defaultValue: "Use lighter weights, or raise one arm at a time.",
                           bundle: .module, comment: "Front raise: an easier version, as a short instruction")
        )
    }

    static var tricepsPushdown: ExerciseHowTo {
        ExerciseHowTo(
            name: "Triceps pushdown", keyStem: "tricepsPushdown",
            displayName: String(localized: "exercise.tricepsPushdown.name", defaultValue: "Triceps pushdown",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.tricepsPushdown.cue1", defaultValue: "Set the pulley high and grip the bar or rope.",
                       bundle: .module, comment: "Triceps pushdown: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.tricepsPushdown.cue2", defaultValue: "Pin your elbows to your sides and stand tall.",
                       bundle: .module, comment: "Triceps pushdown: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.tricepsPushdown.cue3", defaultValue: "Push down until your arms are straight, then pause.",
                       bundle: .module, comment: "Triceps pushdown: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.tricepsPushdown.cue4", defaultValue: "Let your forearms rise slowly without moving your elbows.",
                       bundle: .module, comment: "Triceps pushdown: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.tricepsPushdown.mistake", defaultValue: "Letting the elbows drift forward and leaning over the weight to push it.",
                            bundle: .module, comment: "Triceps pushdown: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.tricepsPushdown.easier", defaultValue: "Use a lighter weight, or do the same move with a band.",
                           bundle: .module, comment: "Triceps pushdown: an easier version, as a short instruction")
        )
    }

    static var skullcrusher: ExerciseHowTo {
        ExerciseHowTo(
            name: "Skullcrusher", keyStem: "skullcrusher",
            displayName: String(localized: "exercise.skullcrusher.name", defaultValue: "Skullcrusher",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.skullcrusher.cue1", defaultValue: "Lie on a bench holding the bar above your chest.",
                       bundle: .module, comment: "Skullcrusher: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.skullcrusher.cue2", defaultValue: "Use a narrow grip with your elbows pointing at the ceiling.",
                       bundle: .module, comment: "Skullcrusher: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.skullcrusher.cue3", defaultValue: "Bend only your elbows, lowering the bar to just above your forehead.",
                       bundle: .module, comment: "Skullcrusher: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.skullcrusher.cue4", defaultValue: "Keep your upper arms still as you press back up.",
                       bundle: .module, comment: "Skullcrusher: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.skullcrusher.mistake", defaultValue: "Letting the elbows flare out wide and the upper arms swing.",
                            bundle: .module, comment: "Skullcrusher: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.skullcrusher.easier", defaultValue: "Use light dumbbells with your palms facing each other.",
                           bundle: .module, comment: "Skullcrusher: an easier version, as a short instruction")
        )
    }

    static var closeGripBench: ExerciseHowTo {
        ExerciseHowTo(
            name: "Close-grip bench", keyStem: "closeGripBench",
            displayName: String(localized: "exercise.closeGripBench.name", defaultValue: "Close-grip bench",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.closeGripBench.cue1", defaultValue: "Set the safety arms, or have someone spot you.",
                       bundle: .module, comment: "Close-grip bench: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.closeGripBench.cue2", defaultValue: "Grip the bar about shoulder-width apart, not narrower.",
                       bundle: .module, comment: "Close-grip bench: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.closeGripBench.cue3", defaultValue: "Keep your elbows tucked close to your sides as you lower.",
                       bundle: .module, comment: "Close-grip bench: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.closeGripBench.cue4", defaultValue: "Touch the bar lightly to your lower chest.",
                       bundle: .module, comment: "Close-grip bench: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.closeGripBench.cue5", defaultValue: "Press up until your arms are straight.",
                       bundle: .module, comment: "Close-grip bench: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.closeGripBench.mistake", defaultValue: "Gripping so narrow that the wrists bend back under the bar.",
                            bundle: .module, comment: "Close-grip bench: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.closeGripBench.easier", defaultValue: "Do close-grip push-ups with your hands on a bench.",
                           bundle: .module, comment: "Close-grip bench: an easier version, as a short instruction")
        )
    }

    static var pikePushUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Pike push-up", keyStem: "pikePushUp",
            displayName: String(localized: "exercise.pikePushUp.name", defaultValue: "Pike push-up",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.pikePushUp.cue1", defaultValue: "Start in a push-up position, then walk your feet in.",
                       bundle: .module, comment: "Pike push-up: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.pikePushUp.cue2", defaultValue: "Lift your hips high so your body forms an upside-down V.",
                       bundle: .module, comment: "Pike push-up: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.pikePushUp.cue3", defaultValue: "Bend your elbows and lower your head toward the floor.",
                       bundle: .module, comment: "Pike push-up: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.pikePushUp.cue4", defaultValue: "Press back up until your arms are straight.",
                       bundle: .module, comment: "Pike push-up: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.pikePushUp.mistake", defaultValue: "Letting the hips drop so it turns into a regular push-up.",
                            bundle: .module, comment: "Pike push-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.pikePushUp.easier", defaultValue: "Put your hands on a bench and keep the bend small.",
                           bundle: .module, comment: "Pike push-up: an easier version, as a short instruction")
        )
    }

    static var bandChestPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band chest press", keyStem: "bandChestPress",
            displayName: String(localized: "exercise.bandChestPress.name", defaultValue: "Band chest press",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandChestPress.cue1", defaultValue: "Anchor the band behind you at chest height.",
                       bundle: .module, comment: "Band chest press: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandChestPress.cue2", defaultValue: "Hold a handle in each hand and step forward to add tension.",
                       bundle: .module, comment: "Band chest press: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandChestPress.cue3", defaultValue: "Press your hands forward until your arms are straight.",
                       bundle: .module, comment: "Band chest press: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandChestPress.cue4", defaultValue: "Return slowly, elbows just below your shoulders.",
                       bundle: .module, comment: "Band chest press: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandChestPress.mistake", defaultValue: "Letting the band snap the hands back quickly.",
                            bundle: .module, comment: "Band chest press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandChestPress.easier", defaultValue: "Use a lighter band, or stand closer to the anchor.",
                           bundle: .module, comment: "Band chest press: an easier version, as a short instruction")
        )
    }

    static var bandOverheadPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band overhead press", keyStem: "bandOverheadPress",
            displayName: String(localized: "exercise.bandOverheadPress.name", defaultValue: "Band overhead press",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandOverheadPress.cue1", defaultValue: "Stand on the band with feet hip-width apart.",
                       bundle: .module, comment: "Band overhead press: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandOverheadPress.cue2", defaultValue: "Hold the handles at shoulder height, palms forward.",
                       bundle: .module, comment: "Band overhead press: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandOverheadPress.cue3", defaultValue: "Brace your stomach and press straight overhead.",
                       bundle: .module, comment: "Band overhead press: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandOverheadPress.cue4", defaultValue: "Lower slowly back to your shoulders.",
                       bundle: .module, comment: "Band overhead press: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandOverheadPress.mistake", defaultValue: "Arching the lower back to push the hands up.",
                            bundle: .module, comment: "Band overhead press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandOverheadPress.easier", defaultValue: "Use a lighter band, or stand on it with one foot.",
                           bundle: .module, comment: "Band overhead press: an easier version, as a short instruction")
        )
    }

    static var bandTricepsPushdown: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band triceps pushdown", keyStem: "bandTricepsPushdown",
            displayName: String(localized: "exercise.bandTricepsPushdown.name", defaultValue: "Band triceps pushdown",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandTricepsPushdown.cue1", defaultValue: "Anchor the band high, above a door or bar.",
                       bundle: .module, comment: "Band triceps pushdown: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandTricepsPushdown.cue2", defaultValue: "Pin your elbows to your sides.",
                       bundle: .module, comment: "Band triceps pushdown: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandTricepsPushdown.cue3", defaultValue: "Push your hands down until your arms are straight.",
                       bundle: .module, comment: "Band triceps pushdown: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandTricepsPushdown.cue4", defaultValue: "Let your hands rise slowly without moving your elbows.",
                       bundle: .module, comment: "Band triceps pushdown: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandTricepsPushdown.mistake", defaultValue: "Letting the elbows lift forward as the hands rise.",
                            bundle: .module, comment: "Band triceps pushdown: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandTricepsPushdown.easier", defaultValue: "Use a lighter band, or step closer to the anchor.",
                           bundle: .module, comment: "Band triceps pushdown: an easier version, as a short instruction")
        )
    }

    static var bandLateralRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band lateral raise", keyStem: "bandLateralRaise",
            displayName: String(localized: "exercise.bandLateralRaise.name", defaultValue: "Band lateral raise",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandLateralRaise.cue1", defaultValue: "Stand on the middle of the band, an end in each hand.",
                       bundle: .module, comment: "Band lateral raise: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandLateralRaise.cue2", defaultValue: "Raise your arms out to the sides, elbows slightly bent.",
                       bundle: .module, comment: "Band lateral raise: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandLateralRaise.cue3", defaultValue: "Stop at about shoulder height.",
                       bundle: .module, comment: "Band lateral raise: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandLateralRaise.cue4", defaultValue: "Lower slowly back to your sides.",
                       bundle: .module, comment: "Band lateral raise: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandLateralRaise.mistake", defaultValue: "Shrugging the shoulders toward the ears as the arms rise.",
                            bundle: .module, comment: "Band lateral raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandLateralRaise.easier", defaultValue: "Use a lighter band, or work one arm at a time.",
                           bundle: .module, comment: "Band lateral raise: an easier version, as a short instruction")
        )
    }

    static var dumbbellShoulderPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell shoulder press", keyStem: "dumbbellShoulderPress",
            displayName: String(localized: "exercise.dumbbellShoulderPress.name", defaultValue: "Dumbbell shoulder press",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellShoulderPress.cue1", defaultValue: "Sit or stand tall with dumbbells at shoulder height.",
                       bundle: .module, comment: "Dumbbell shoulder press: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellShoulderPress.cue2", defaultValue: "Face your palms forward or toward each other.",
                       bundle: .module, comment: "Dumbbell shoulder press: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellShoulderPress.cue3", defaultValue: "Brace your stomach and press straight up.",
                       bundle: .module, comment: "Dumbbell shoulder press: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellShoulderPress.cue4", defaultValue: "Lower slowly until the weights are back at your shoulders.",
                       bundle: .module, comment: "Dumbbell shoulder press: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellShoulderPress.mistake", defaultValue: "Arching the lower back to push heavy weights overhead.",
                            bundle: .module, comment: "Dumbbell shoulder press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellShoulderPress.easier", defaultValue: "Sit with your back supported and use lighter dumbbells.",
                           bundle: .module, comment: "Dumbbell shoulder press: an easier version, as a short instruction")
        )
    }

    static var arnoldPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Arnold press", keyStem: "arnoldPress",
            displayName: String(localized: "exercise.arnoldPress.name", defaultValue: "Arnold press",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.arnoldPress.cue1", defaultValue: "Sit tall with dumbbells at shoulder height, palms facing you.",
                       bundle: .module, comment: "Arnold press: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.arnoldPress.cue2", defaultValue: "Press up while turning your palms to face forward.",
                       bundle: .module, comment: "Arnold press: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.arnoldPress.cue3", defaultValue: "Finish with your arms straight overhead.",
                       bundle: .module, comment: "Arnold press: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.arnoldPress.cue4", defaultValue: "Reverse the turn as you lower slowly.",
                       bundle: .module, comment: "Arnold press: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.arnoldPress.mistake", defaultValue: "Rushing the turn and arching the lower back.",
                            bundle: .module, comment: "Arnold press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.arnoldPress.easier", defaultValue: "Do a regular dumbbell shoulder press with lighter weights.",
                           bundle: .module, comment: "Arnold press: an easier version, as a short instruction")
        )
    }

    static var inclineDumbbellPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Incline dumbbell press", keyStem: "inclineDumbbellPress",
            displayName: String(localized: "exercise.inclineDumbbellPress.name", defaultValue: "Incline dumbbell press",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.inclineDumbbellPress.cue1", defaultValue: "Set the bench to a low incline.",
                       bundle: .module, comment: "Incline dumbbell press: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.inclineDumbbellPress.cue2", defaultValue: "Start with the dumbbells over your upper chest.",
                       bundle: .module, comment: "Incline dumbbell press: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.inclineDumbbellPress.cue3", defaultValue: "Lower slowly, elbows angled slightly in.",
                       bundle: .module, comment: "Incline dumbbell press: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.inclineDumbbellPress.cue4", defaultValue: "Press up and together until your arms are straight.",
                       bundle: .module, comment: "Incline dumbbell press: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.inclineDumbbellPress.mistake", defaultValue: "Setting the bench too steep so the shoulders do most of the work.",
                            bundle: .module, comment: "Incline dumbbell press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.inclineDumbbellPress.easier", defaultValue: "Use lighter dumbbells and a lower incline.",
                           bundle: .module, comment: "Incline dumbbell press: an easier version, as a short instruction")
        )
    }

    static var dumbbellFloorPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell floor press", keyStem: "dumbbellFloorPress",
            displayName: String(localized: "exercise.dumbbellFloorPress.name", defaultValue: "Dumbbell floor press",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellFloorPress.cue1", defaultValue: "Lie on the floor, knees bent, dumbbells over your chest.",
                       bundle: .module, comment: "Dumbbell floor press: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellFloorPress.cue2", defaultValue: "Lower until your upper arms rest lightly on the floor.",
                       bundle: .module, comment: "Dumbbell floor press: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellFloorPress.cue3", defaultValue: "Keep your elbows angled slightly in.",
                       bundle: .module, comment: "Dumbbell floor press: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellFloorPress.cue4", defaultValue: "Press up until your arms are straight.",
                       bundle: .module, comment: "Dumbbell floor press: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellFloorPress.mistake", defaultValue: "Letting the elbows thump down onto the floor.",
                            bundle: .module, comment: "Dumbbell floor press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellFloorPress.easier", defaultValue: "Use lighter dumbbells, or press one arm at a time.",
                           bundle: .module, comment: "Dumbbell floor press: an easier version, as a short instruction")
        )
    }

    static var inclinePushUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Incline push-up", keyStem: "inclinePushUp",
            displayName: String(localized: "exercise.inclinePushUp.name", defaultValue: "Incline push-up",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.inclinePushUp.cue1", defaultValue: "Place your hands on a sturdy bench, table or wall.",
                       bundle: .module, comment: "Incline push-up: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.inclinePushUp.cue2", defaultValue: "Walk your feet back until your body is a straight line.",
                       bundle: .module, comment: "Incline push-up: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.inclinePushUp.cue3", defaultValue: "Lower your chest toward the edge.",
                       bundle: .module, comment: "Incline push-up: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.inclinePushUp.cue4", defaultValue: "Push away until your arms are straight.",
                       bundle: .module, comment: "Incline push-up: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.inclinePushUp.mistake", defaultValue: "Letting the hips sag or bending at the waist.",
                            bundle: .module, comment: "Incline push-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.inclinePushUp.easier", defaultValue: "Use a higher surface, such as a wall.",
                           bundle: .module, comment: "Incline push-up: an easier version, as a short instruction")
        )
    }

    static var dumbbellFly: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell fly", keyStem: "dumbbellFly",
            displayName: String(localized: "exercise.dumbbellFly.name", defaultValue: "Dumbbell fly",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellFly.cue1", defaultValue: "Lie on a bench with the dumbbells above your chest.",
                       bundle: .module, comment: "Dumbbell fly: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellFly.cue2", defaultValue: "Keep a soft bend in your elbows the whole time.",
                       bundle: .module, comment: "Dumbbell fly: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellFly.cue3", defaultValue: "Open your arms wide in a slow arc.",
                       bundle: .module, comment: "Dumbbell fly: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellFly.cue4", defaultValue: "Stop at a light stretch across your chest.",
                       bundle: .module, comment: "Dumbbell fly: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellFly.cue5", defaultValue: "Bring the weights back together over your chest.",
                       bundle: .module, comment: "Dumbbell fly: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellFly.mistake", defaultValue: "Lowering too deep with weights that are too heavy.",
                            bundle: .module, comment: "Dumbbell fly: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellFly.easier", defaultValue: "Use lighter dumbbells and a smaller arc.",
                           bundle: .module, comment: "Dumbbell fly: an easier version, as a short instruction")
        )
    }
}
