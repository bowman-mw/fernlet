// ExerciseHowTo+Legs.swift
// FernletDomainModel — how-to text for the catalog's legs and hips: squats, lunges, hinges, bridges, calf and hip work.
//
// Fernlet-written, clean-room text (no website, dataset or book was copied or paraphrased),
// awaiting one review by a qualified coach before it ships. Every string is a catalog key under
// `exercise.<keyStem>.` resolved against `.module`; the English default here is what
// Scripts/sync-string-catalogs.sh harvests into Localizable.xcstrings, so edit both together.

import Foundation

extension ExerciseHowToCatalog {
    /// Legs and hips: squats, lunges, hinges, bridges, calf and hip work. In catalog order.
    static var legEntries: [ExerciseHowTo] {
        [
            backSquat,
            frontSquat,
            gobletSquat,
            legPress,
            hackSquat,
            bulgarianSplitSquat,
            lunge,
            stepUp,
            legExtension,
            deadlift,
            romanianDeadlift,
            hipThrust,
            gluteBridge,
            goodMorning,
            hyperextension,
            legCurl,
            standingCalfRaise,
            seatedCalfRaise,
            bodyweightSquat,
            reverseLunge,
            calfRaise,
            nordicCurl,
            singleLegGluteBridge,
            bandGoodMorning,
            bandSquat,
            dumbbellRomanianDeadlift,
            kettlebellDeadlift,
            lateralBandWalk,
            clamshell,
            boxSquat,
            wallSit,
            dumbbellFrontSquat,
            pistolSquatToBox,
            smithMachineSquat,
            splitSquat,
            sideLunge,
            walkingLunge,
            dumbbellSingleLegRomanianDeadlift,
            bodyweightSingleLegDeadlift,
            bodyweightGoodMorning,
            dumbbellGluteBridge,
            dumbbellHipThrust,
            bandPullThrough,
            singleLegCalfRaise,
            dumbbellSingleLegCalfRaise,
            cableGluteKickback,
            hipAbductionMachine,
            hipAdductionMachine,
            cablePullThrough,
            donkeyKick,
        ]
    }

    static var backSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Back squat", keyStem: "backSquat",
            displayName: String(localized: "exercise.backSquat.name", defaultValue: "Back squat",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.backSquat.cue1", defaultValue: "Set the safety arms just below your lowest squat depth.",
                       bundle: .module, comment: "Back squat: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.backSquat.cue2", defaultValue: "Rest the bar across your upper back, not on your neck.",
                       bundle: .module, comment: "Back squat: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.backSquat.cue3", defaultValue: "Brace your stomach, feet about shoulder-width, toes turned out a little.",
                       bundle: .module, comment: "Back squat: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.backSquat.cue4", defaultValue: "Sit down between your hips, knees tracking over your toes.",
                       bundle: .module, comment: "Back squat: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.backSquat.cue5", defaultValue: "Drive through your whole foot to stand back up.",
                       bundle: .module, comment: "Back squat: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.backSquat.mistake", defaultValue: "Letting the knees cave inward or the heels lift as you stand.",
                            bundle: .module, comment: "Back squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.backSquat.easier", defaultValue: "Do goblet squats with one weight at your chest, or squat to a bench.",
                           bundle: .module, comment: "Back squat: an easier version, as a short instruction")
        )
    }

    static var frontSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Front squat", keyStem: "frontSquat",
            displayName: String(localized: "exercise.frontSquat.name", defaultValue: "Front squat",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.frontSquat.cue1", defaultValue: "Set the safety arms just below your lowest depth.",
                       bundle: .module, comment: "Front squat: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.frontSquat.cue2", defaultValue: "Rest the bar on the front of your shoulders, near your throat.",
                       bundle: .module, comment: "Front squat: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.frontSquat.cue3", defaultValue: "Lift your elbows high so your upper arms point forward.",
                       bundle: .module, comment: "Front squat: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.frontSquat.cue4", defaultValue: "Stay upright and sit straight down between your heels.",
                       bundle: .module, comment: "Front squat: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.frontSquat.cue5", defaultValue: "Keep your elbows up as you drive back to standing.",
                       bundle: .module, comment: "Front squat: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.frontSquat.mistake", defaultValue: "Dropping the elbows so the bar rolls forward and the back rounds.",
                            bundle: .module, comment: "Front squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.frontSquat.easier", defaultValue: "Do goblet squats, which keep the same upright posture with less load.",
                           bundle: .module, comment: "Front squat: an easier version, as a short instruction")
        )
    }

    static var gobletSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Goblet squat", keyStem: "gobletSquat",
            displayName: String(localized: "exercise.gobletSquat.name", defaultValue: "Goblet squat",
                                bundle: .module, comment: "Exercise name shown on screen (kettlebell exercise)"),
            cues: [
                String(localized: "exercise.gobletSquat.cue1", defaultValue: "Hold one weight against your chest with both hands.",
                       bundle: .module, comment: "Goblet squat: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.gobletSquat.cue2", defaultValue: "Stand with your feet a little wider than your hips.",
                       bundle: .module, comment: "Goblet squat: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.gobletSquat.cue3", defaultValue: "Sit down between your knees, chest staying tall.",
                       bundle: .module, comment: "Goblet squat: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.gobletSquat.cue4", defaultValue: "Push your knees out in line with your toes.",
                       bundle: .module, comment: "Goblet squat: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.gobletSquat.cue5", defaultValue: "Stand up by pressing through your whole foot.",
                       bundle: .module, comment: "Goblet squat: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.gobletSquat.mistake", defaultValue: "Letting the chest drop forward and the heels lift off the floor.",
                            bundle: .module, comment: "Goblet squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.gobletSquat.easier", defaultValue: "Use a lighter weight, or squat down to a bench or chair.",
                           bundle: .module, comment: "Goblet squat: an easier version, as a short instruction")
        )
    }

    static var legPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Leg press", keyStem: "legPress",
            displayName: String(localized: "exercise.legPress.name", defaultValue: "Leg press",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.legPress.cue1", defaultValue: "Sit with your back and hips flat against the pad.",
                       bundle: .module, comment: "Leg press: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.legPress.cue2", defaultValue: "Place your feet hip-width apart in the middle of the platform.",
                       bundle: .module, comment: "Leg press: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.legPress.cue3", defaultValue: "Release the safety handles and lower the platform with control.",
                       bundle: .module, comment: "Leg press: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.legPress.cue4", defaultValue: "Stop before your lower back starts to lift off the pad.",
                       bundle: .module, comment: "Leg press: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.legPress.cue5", defaultValue: "Press back up without fully locking your knees.",
                       bundle: .module, comment: "Leg press: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.legPress.mistake", defaultValue: "Lowering so deep that the hips curl up off the seat.",
                            bundle: .module, comment: "Leg press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.legPress.easier", defaultValue: "Use a lighter weight and a shorter range, or do bodyweight squats.",
                           bundle: .module, comment: "Leg press: an easier version, as a short instruction")
        )
    }

    static var hackSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hack squat", keyStem: "hackSquat",
            displayName: String(localized: "exercise.hackSquat.name", defaultValue: "Hack squat",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.hackSquat.cue1", defaultValue: "Stand with your back and shoulders flat against the pads.",
                       bundle: .module, comment: "Hack squat: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.hackSquat.cue2", defaultValue: "Set your feet shoulder-width apart in the middle of the platform.",
                       bundle: .module, comment: "Hack squat: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.hackSquat.cue3", defaultValue: "Release the safety handles and bend your knees slowly.",
                       bundle: .module, comment: "Hack squat: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.hackSquat.cue4", defaultValue: "Lower only as far as your back stays flat on the pad.",
                       bundle: .module, comment: "Hack squat: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.hackSquat.cue5", defaultValue: "Push through your whole foot to straighten back up.",
                       bundle: .module, comment: "Hack squat: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hackSquat.mistake", defaultValue: "Letting the heels lift or the knees cave in at the bottom.",
                            bundle: .module, comment: "Hack squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hackSquat.easier", defaultValue: "Use less weight and stop higher, or do goblet squats.",
                           bundle: .module, comment: "Hack squat: an easier version, as a short instruction")
        )
    }

    static var bulgarianSplitSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Bulgarian split squat", keyStem: "bulgarianSplitSquat",
            displayName: String(localized: "exercise.bulgarianSplitSquat.name", defaultValue: "Bulgarian split squat",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.bulgarianSplitSquat.cue1", defaultValue: "Stand facing away from a bench, rear foot resting on it.",
                       bundle: .module, comment: "Bulgarian split squat: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.bulgarianSplitSquat.cue2", defaultValue: "Hold dumbbells at your sides and keep your chest tall.",
                       bundle: .module, comment: "Bulgarian split squat: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.bulgarianSplitSquat.cue3", defaultValue: "Lower straight down, front thigh about level with the floor.",
                       bundle: .module, comment: "Bulgarian split squat: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.bulgarianSplitSquat.cue4", defaultValue: "Keep your front knee in line with your middle toes.",
                       bundle: .module, comment: "Bulgarian split squat: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.bulgarianSplitSquat.cue5", defaultValue: "Push through your front heel to rise, then switch legs.",
                       bundle: .module, comment: "Bulgarian split squat: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bulgarianSplitSquat.mistake", defaultValue: "Standing too close to the bench so the front heel lifts.",
                            bundle: .module, comment: "Bulgarian split squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bulgarianSplitSquat.easier", defaultValue: "Skip the weights, or keep your back foot on the floor.",
                           bundle: .module, comment: "Bulgarian split squat: an easier version, as a short instruction")
        )
    }

    static var lunge: ExerciseHowTo {
        ExerciseHowTo(
            name: "Lunge", keyStem: "lunge",
            displayName: String(localized: "exercise.lunge.name", defaultValue: "Lunge",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.lunge.cue1", defaultValue: "Stand tall holding dumbbells at your sides.",
                       bundle: .module, comment: "Lunge: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.lunge.cue2", defaultValue: "Step forward a long stride and bend both knees.",
                       bundle: .module, comment: "Lunge: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.lunge.cue3", defaultValue: "Lower until your back knee nearly touches the floor.",
                       bundle: .module, comment: "Lunge: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.lunge.cue4", defaultValue: "Keep your front knee in line with your toes.",
                       bundle: .module, comment: "Lunge: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.lunge.cue5", defaultValue: "Push through your front foot to step back to standing.",
                       bundle: .module, comment: "Lunge: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.lunge.mistake", defaultValue: "Taking too short a step, so the front heel lifts off the floor.",
                            bundle: .module, comment: "Lunge: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.lunge.easier", defaultValue: "Do reverse lunges without weights, holding a support for balance.",
                           bundle: .module, comment: "Lunge: an easier version, as a short instruction")
        )
    }

    static var stepUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Step-up", keyStem: "stepUp",
            displayName: String(localized: "exercise.stepUp.name", defaultValue: "Step-up",
                                bundle: .module, comment: "Exercise name shown on screen (exercise done on a bench)"),
            cues: [
                String(localized: "exercise.stepUp.cue1", defaultValue: "Face a sturdy bench or box at about knee height.",
                       bundle: .module, comment: "Step-up: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.stepUp.cue2", defaultValue: "Place your whole foot on top of it.",
                       bundle: .module, comment: "Step-up: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.stepUp.cue3", defaultValue: "Lean forward slightly and push through that foot to stand up.",
                       bundle: .module, comment: "Step-up: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.stepUp.cue4", defaultValue: "Bring the other foot up, then step down slowly.",
                       bundle: .module, comment: "Step-up: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.stepUp.cue5", defaultValue: "Do all your reps on one side, then switch.",
                       bundle: .module, comment: "Step-up: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.stepUp.mistake", defaultValue: "Pushing off the back foot instead of letting the top leg do the work.",
                            bundle: .module, comment: "Step-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.stepUp.easier", defaultValue: "Use a lower step and hold a wall or rail for balance.",
                           bundle: .module, comment: "Step-up: an easier version, as a short instruction")
        )
    }

    static var legExtension: ExerciseHowTo {
        ExerciseHowTo(
            name: "Leg extension", keyStem: "legExtension",
            displayName: String(localized: "exercise.legExtension.name", defaultValue: "Leg extension",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.legExtension.cue1", defaultValue: "Line your knees up with the machine's pivot point.",
                       bundle: .module, comment: "Leg extension: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.legExtension.cue2", defaultValue: "Set the pad against your lower shins, just above the ankles.",
                       bundle: .module, comment: "Leg extension: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.legExtension.cue3", defaultValue: "Straighten your legs smoothly and pause at the top.",
                       bundle: .module, comment: "Leg extension: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.legExtension.cue4", defaultValue: "Lower slowly before the weights touch down.",
                       bundle: .module, comment: "Leg extension: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.legExtension.mistake", defaultValue: "Kicking the weight up fast and letting it drop.",
                            bundle: .module, comment: "Leg extension: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.legExtension.easier", defaultValue: "Use a lighter weight and a smaller range of motion.",
                           bundle: .module, comment: "Leg extension: an easier version, as a short instruction")
        )
    }

    static var deadlift: ExerciseHowTo {
        ExerciseHowTo(
            name: "Deadlift", keyStem: "deadlift",
            displayName: String(localized: "exercise.deadlift.name", defaultValue: "Deadlift",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.deadlift.cue1", defaultValue: "Stand with the bar over your mid-foot, feet hip-width apart.",
                       bundle: .module, comment: "Deadlift: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.deadlift.cue2", defaultValue: "Hinge down and grip the bar just outside your legs.",
                       bundle: .module, comment: "Deadlift: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.deadlift.cue3", defaultValue: "Flatten your back and pull the slack out of the bar.",
                       bundle: .module, comment: "Deadlift: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.deadlift.cue4", defaultValue: "Push the floor away, keeping the bar close to your legs.",
                       bundle: .module, comment: "Deadlift: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.deadlift.cue5", defaultValue: "Stand tall, then lower by pushing your hips back first.",
                       bundle: .module, comment: "Deadlift: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.deadlift.mistake", defaultValue: "Rounding the back and jerking the bar off the floor.",
                            bundle: .module, comment: "Deadlift: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.deadlift.easier", defaultValue: "Deadlift a kettlebell, or pull the bar from raised blocks.",
                           bundle: .module, comment: "Deadlift: an easier version, as a short instruction")
        )
    }

    static var romanianDeadlift: ExerciseHowTo {
        ExerciseHowTo(
            name: "Romanian deadlift", keyStem: "romanianDeadlift",
            displayName: String(localized: "exercise.romanianDeadlift.name", defaultValue: "Romanian deadlift",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.romanianDeadlift.cue1", defaultValue: "Start standing, holding the bar at your thighs.",
                       bundle: .module, comment: "Romanian deadlift: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.romanianDeadlift.cue2", defaultValue: "Soften your knees and push your hips straight back.",
                       bundle: .module, comment: "Romanian deadlift: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.romanianDeadlift.cue3", defaultValue: "Slide the bar down your thighs with your back flat.",
                       bundle: .module, comment: "Romanian deadlift: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.romanianDeadlift.cue4", defaultValue: "Stop when you feel a stretch in your hamstrings.",
                       bundle: .module, comment: "Romanian deadlift: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.romanianDeadlift.cue5", defaultValue: "Squeeze your glutes to bring your hips forward and stand.",
                       bundle: .module, comment: "Romanian deadlift: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.romanianDeadlift.mistake", defaultValue: "Rounding the back to reach the bar lower than the hips allow.",
                            bundle: .module, comment: "Romanian deadlift: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.romanianDeadlift.easier", defaultValue: "Use light dumbbells, and stop just below your knees.",
                           bundle: .module, comment: "Romanian deadlift: an easier version, as a short instruction")
        )
    }

    static var hipThrust: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hip thrust", keyStem: "hipThrust",
            displayName: String(localized: "exercise.hipThrust.name", defaultValue: "Hip thrust",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.hipThrust.cue1", defaultValue: "Sit with your upper back against the edge of a bench.",
                       bundle: .module, comment: "Hip thrust: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.hipThrust.cue2", defaultValue: "Roll a padded bar over your hips, feet flat.",
                       bundle: .module, comment: "Hip thrust: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.hipThrust.cue3", defaultValue: "Drive through your heels to lift your hips.",
                       bundle: .module, comment: "Hip thrust: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.hipThrust.cue4", defaultValue: "Finish with knees, hips and shoulders in a line.",
                       bundle: .module, comment: "Hip thrust: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.hipThrust.cue5", defaultValue: "Tuck your chin slightly and lower with control.",
                       bundle: .module, comment: "Hip thrust: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hipThrust.mistake", defaultValue: "Arching the lower back at the top instead of squeezing the glutes.",
                            bundle: .module, comment: "Hip thrust: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hipThrust.easier", defaultValue: "Do glute bridges on the floor, with or without a weight.",
                           bundle: .module, comment: "Hip thrust: an easier version, as a short instruction")
        )
    }

    static var gluteBridge: ExerciseHowTo {
        ExerciseHowTo(
            name: "Glute bridge", keyStem: "gluteBridge",
            displayName: String(localized: "exercise.gluteBridge.name", defaultValue: "Glute bridge",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.gluteBridge.cue1", defaultValue: "Lie on your back, knees bent, feet flat near your hips.",
                       bundle: .module, comment: "Glute bridge: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.gluteBridge.cue2", defaultValue: "Press your lower back gently toward the floor.",
                       bundle: .module, comment: "Glute bridge: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.gluteBridge.cue3", defaultValue: "Push through your heels and lift your hips.",
                       bundle: .module, comment: "Glute bridge: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.gluteBridge.cue4", defaultValue: "Squeeze your glutes at the top, then lower slowly.",
                       bundle: .module, comment: "Glute bridge: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.gluteBridge.mistake", defaultValue: "Pushing the hips so high that the lower back arches.",
                            bundle: .module, comment: "Glute bridge: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.gluteBridge.easier", defaultValue: "Lift your hips only partway, and rest briefly between reps.",
                           bundle: .module, comment: "Glute bridge: an easier version, as a short instruction")
        )
    }

    static var goodMorning: ExerciseHowTo {
        ExerciseHowTo(
            name: "Good morning", keyStem: "goodMorning",
            displayName: String(localized: "exercise.goodMorning.name", defaultValue: "Good morning",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.goodMorning.cue1", defaultValue: "Start light, with the bar across your upper back.",
                       bundle: .module, comment: "Good morning: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.goodMorning.cue2", defaultValue: "Soften your knees and brace your stomach.",
                       bundle: .module, comment: "Good morning: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.goodMorning.cue3", defaultValue: "Push your hips back and tip your chest forward, back flat.",
                       bundle: .module, comment: "Good morning: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.goodMorning.cue4", defaultValue: "Stop when you feel a stretch in your hamstrings.",
                       bundle: .module, comment: "Good morning: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.goodMorning.cue5", defaultValue: "Drive your hips forward to stand tall again.",
                       bundle: .module, comment: "Good morning: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.goodMorning.mistake", defaultValue: "Bending too far and letting the back round under the bar.",
                            bundle: .module, comment: "Good morning: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.goodMorning.easier", defaultValue: "Do it with a band, or with your hands behind your head.",
                           bundle: .module, comment: "Good morning: an easier version, as a short instruction")
        )
    }

    static var hyperextension: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hyperextension", keyStem: "hyperextension",
            displayName: String(localized: "exercise.hyperextension.name", defaultValue: "Hyperextension",
                                bundle: .module, comment: "Exercise name shown on screen (exercise done on a bench)"),
            cues: [
                String(localized: "exercise.hyperextension.cue1", defaultValue: "Set the pad just below your hip bones.",
                       bundle: .module, comment: "Hyperextension: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.hyperextension.cue2", defaultValue: "Hook your heels under the footpads and cross your arms.",
                       bundle: .module, comment: "Hyperextension: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.hyperextension.cue3", defaultValue: "Lower your chest with a flat back until you feel a stretch.",
                       bundle: .module, comment: "Hyperextension: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.hyperextension.cue4", defaultValue: "Rise until your body is in a straight line, no higher.",
                       bundle: .module, comment: "Hyperextension: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hyperextension.mistake", defaultValue: "Swinging up past straight and arching the lower back hard.",
                            bundle: .module, comment: "Hyperextension: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hyperextension.easier", defaultValue: "Do the superman or the bird dog on the floor.",
                           bundle: .module, comment: "Hyperextension: an easier version, as a short instruction")
        )
    }

    static var legCurl: ExerciseHowTo {
        ExerciseHowTo(
            name: "Leg curl", keyStem: "legCurl",
            displayName: String(localized: "exercise.legCurl.name", defaultValue: "Leg curl",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.legCurl.cue1", defaultValue: "Line your knees up with the machine's pivot point.",
                       bundle: .module, comment: "Leg curl: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.legCurl.cue2", defaultValue: "Set the pad on your lower calves, above your heels.",
                       bundle: .module, comment: "Leg curl: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.legCurl.cue3", defaultValue: "Curl your heels toward your glutes and pause.",
                       bundle: .module, comment: "Leg curl: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.legCurl.cue4", defaultValue: "Return slowly to almost straight legs.",
                       bundle: .module, comment: "Leg curl: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.legCurl.mistake", defaultValue: "Lifting the hips off the pad to jerk the weight up.",
                            bundle: .module, comment: "Leg curl: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.legCurl.easier", defaultValue: "Use a lighter weight and a shorter range of motion.",
                           bundle: .module, comment: "Leg curl: an easier version, as a short instruction")
        )
    }

    static var standingCalfRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Standing calf raise", keyStem: "standingCalfRaise",
            displayName: String(localized: "exercise.standingCalfRaise.name", defaultValue: "Standing calf raise",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.standingCalfRaise.cue1", defaultValue: "Stand with the balls of your feet on the platform edge.",
                       bundle: .module, comment: "Standing calf raise: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.standingCalfRaise.cue2", defaultValue: "Let your heels sink below the edge for a gentle stretch.",
                       bundle: .module, comment: "Standing calf raise: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.standingCalfRaise.cue3", defaultValue: "Rise as high as you can onto your toes.",
                       bundle: .module, comment: "Standing calf raise: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.standingCalfRaise.cue4", defaultValue: "Pause at the top, then lower slowly.",
                       bundle: .module, comment: "Standing calf raise: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.standingCalfRaise.mistake", defaultValue: "Bouncing quickly at the bottom instead of moving smoothly.",
                            bundle: .module, comment: "Standing calf raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.standingCalfRaise.easier", defaultValue: "Use less weight, or do calf raises on flat ground.",
                           bundle: .module, comment: "Standing calf raise: an easier version, as a short instruction")
        )
    }

    static var seatedCalfRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Seated calf raise", keyStem: "seatedCalfRaise",
            displayName: String(localized: "exercise.seatedCalfRaise.name", defaultValue: "Seated calf raise",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.seatedCalfRaise.cue1", defaultValue: "Sit with the pad resting on your lower thighs.",
                       bundle: .module, comment: "Seated calf raise: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.seatedCalfRaise.cue2", defaultValue: "Place the balls of your feet on the platform edge.",
                       bundle: .module, comment: "Seated calf raise: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.seatedCalfRaise.cue3", defaultValue: "Lower your heels slowly for a gentle stretch.",
                       bundle: .module, comment: "Seated calf raise: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.seatedCalfRaise.cue4", defaultValue: "Push up onto your toes and pause at the top.",
                       bundle: .module, comment: "Seated calf raise: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.seatedCalfRaise.mistake", defaultValue: "Bouncing through short, fast reps.",
                            bundle: .module, comment: "Seated calf raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.seatedCalfRaise.easier", defaultValue: "Use less weight and a smaller range of motion.",
                           bundle: .module, comment: "Seated calf raise: an easier version, as a short instruction")
        )
    }

    static var bodyweightSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Bodyweight squat", keyStem: "bodyweightSquat",
            displayName: String(localized: "exercise.bodyweightSquat.name", defaultValue: "Bodyweight squat",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.bodyweightSquat.cue1", defaultValue: "Stand with your feet a little wider than your hips.",
                       bundle: .module, comment: "Bodyweight squat: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightSquat.cue2", defaultValue: "Reach your arms forward for balance.",
                       bundle: .module, comment: "Bodyweight squat: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightSquat.cue3", defaultValue: "Sit down and back as if onto a chair.",
                       bundle: .module, comment: "Bodyweight squat: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightSquat.cue4", defaultValue: "Keep your heels down and knees in line with your toes.",
                       bundle: .module, comment: "Bodyweight squat: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightSquat.cue5", defaultValue: "Stand up by pushing through your whole foot.",
                       bundle: .module, comment: "Bodyweight squat: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bodyweightSquat.mistake", defaultValue: "Letting the heels lift and the knees cave inward.",
                            bundle: .module, comment: "Bodyweight squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bodyweightSquat.easier", defaultValue: "Squat down to a chair or bench and stand back up.",
                           bundle: .module, comment: "Bodyweight squat: an easier version, as a short instruction")
        )
    }

    static var reverseLunge: ExerciseHowTo {
        ExerciseHowTo(
            name: "Reverse lunge", keyStem: "reverseLunge",
            displayName: String(localized: "exercise.reverseLunge.name", defaultValue: "Reverse lunge",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.reverseLunge.cue1", defaultValue: "Stand tall with your hands on your hips.",
                       bundle: .module, comment: "Reverse lunge: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.reverseLunge.cue2", defaultValue: "Step one foot back a long stride.",
                       bundle: .module, comment: "Reverse lunge: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.reverseLunge.cue3", defaultValue: "Lower until your back knee nearly touches the floor.",
                       bundle: .module, comment: "Reverse lunge: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.reverseLunge.cue4", defaultValue: "Keep most of your weight on the front foot.",
                       bundle: .module, comment: "Reverse lunge: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.reverseLunge.cue5", defaultValue: "Push through the front foot to step back up.",
                       bundle: .module, comment: "Reverse lunge: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.reverseLunge.mistake", defaultValue: "Placing the back foot directly behind the front one, which makes balance hard.",
                            bundle: .module, comment: "Reverse lunge: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.reverseLunge.easier", defaultValue: "Hold a wall or chair for balance and take a shorter step.",
                           bundle: .module, comment: "Reverse lunge: an easier version, as a short instruction")
        )
    }

    static var calfRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Calf raise", keyStem: "calfRaise",
            displayName: String(localized: "exercise.calfRaise.name", defaultValue: "Calf raise",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.calfRaise.cue1", defaultValue: "Stand tall, holding a wall or rail for balance.",
                       bundle: .module, comment: "Calf raise: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.calfRaise.cue2", defaultValue: "Rise as high as you can onto your toes.",
                       bundle: .module, comment: "Calf raise: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.calfRaise.cue3", defaultValue: "Pause briefly at the top.",
                       bundle: .module, comment: "Calf raise: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.calfRaise.cue4", defaultValue: "Lower your heels slowly to the floor.",
                       bundle: .module, comment: "Calf raise: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.calfRaise.mistake", defaultValue: "Bouncing through quick reps without pausing at the top.",
                            bundle: .module, comment: "Calf raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.calfRaise.easier", defaultValue: "Do it seated, or rise only partway up.",
                           bundle: .module, comment: "Calf raise: an easier version, as a short instruction")
        )
    }

    static var nordicCurl: ExerciseHowTo {
        ExerciseHowTo(
            name: "Nordic curl", keyStem: "nordicCurl",
            displayName: String(localized: "exercise.nordicCurl.name", defaultValue: "Nordic curl",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.nordicCurl.cue1", defaultValue: "Kneel on a pad with your ankles held down firmly.",
                       bundle: .module, comment: "Nordic curl: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.nordicCurl.cue2", defaultValue: "Keep a straight line from your knees to your head.",
                       bundle: .module, comment: "Nordic curl: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.nordicCurl.cue3", defaultValue: "Lean forward as slowly as you can.",
                       bundle: .module, comment: "Nordic curl: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.nordicCurl.cue4", defaultValue: "Catch yourself with your hands, then push back up.",
                       bundle: .module, comment: "Nordic curl: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.nordicCurl.mistake", defaultValue: "Bending at the hips instead of lowering as one straight line.",
                            bundle: .module, comment: "Nordic curl: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.nordicCurl.easier", defaultValue: "Lower only partway, and use your hands to push back up.",
                           bundle: .module, comment: "Nordic curl: an easier version, as a short instruction")
        )
    }

    static var singleLegGluteBridge: ExerciseHowTo {
        ExerciseHowTo(
            name: "Single-leg glute bridge", keyStem: "singleLegGluteBridge",
            displayName: String(localized: "exercise.singleLegGluteBridge.name", defaultValue: "Single-leg glute bridge",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.singleLegGluteBridge.cue1", defaultValue: "Lie on your back, one knee bent and that foot flat.",
                       bundle: .module, comment: "Single-leg glute bridge: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.singleLegGluteBridge.cue2", defaultValue: "Lift the other leg straight, or hug it to your chest.",
                       bundle: .module, comment: "Single-leg glute bridge: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.singleLegGluteBridge.cue3", defaultValue: "Push through the planted heel to raise your hips.",
                       bundle: .module, comment: "Single-leg glute bridge: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.singleLegGluteBridge.cue4", defaultValue: "Keep your hips level as you lift and lower.",
                       bundle: .module, comment: "Single-leg glute bridge: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.singleLegGluteBridge.cue5", defaultValue: "Finish all your reps, then switch legs.",
                       bundle: .module, comment: "Single-leg glute bridge: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.singleLegGluteBridge.mistake", defaultValue: "Letting one hip drop lower than the other.",
                            bundle: .module, comment: "Single-leg glute bridge: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.singleLegGluteBridge.easier", defaultValue: "Do the two-leg glute bridge, or rest the free foot lightly on the floor.",
                           bundle: .module, comment: "Single-leg glute bridge: an easier version, as a short instruction")
        )
    }

    static var bandGoodMorning: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band good morning", keyStem: "bandGoodMorning",
            displayName: String(localized: "exercise.bandGoodMorning.name", defaultValue: "Band good morning",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandGoodMorning.cue1", defaultValue: "Stand on the band and loop it over your upper back.",
                       bundle: .module, comment: "Band good morning: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.bandGoodMorning.cue2", defaultValue: "Soften your knees and keep your back flat.",
                       bundle: .module, comment: "Band good morning: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.bandGoodMorning.cue3", defaultValue: "Push your hips back and lean forward from the hips.",
                       bundle: .module, comment: "Band good morning: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.bandGoodMorning.cue4", defaultValue: "Stop when you feel a stretch in your hamstrings.",
                       bundle: .module, comment: "Band good morning: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.bandGoodMorning.cue5", defaultValue: "Drive your hips forward to stand tall.",
                       bundle: .module, comment: "Band good morning: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandGoodMorning.mistake", defaultValue: "Rounding the back as you lean forward.",
                            bundle: .module, comment: "Band good morning: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandGoodMorning.easier", defaultValue: "Use a lighter band, or practice the hinge with no band.",
                           bundle: .module, comment: "Band good morning: an easier version, as a short instruction")
        )
    }

    static var bandSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band squat", keyStem: "bandSquat",
            displayName: String(localized: "exercise.bandSquat.name", defaultValue: "Band squat",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandSquat.cue1", defaultValue: "Stand on the band with feet shoulder-width apart.",
                       bundle: .module, comment: "Band squat: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandSquat.cue2", defaultValue: "Hold the band at your shoulders.",
                       bundle: .module, comment: "Band squat: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandSquat.cue3", defaultValue: "Sit down between your hips, chest tall.",
                       bundle: .module, comment: "Band squat: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandSquat.cue4", defaultValue: "Push through your whole foot to stand up.",
                       bundle: .module, comment: "Band squat: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandSquat.mistake", defaultValue: "Letting the knees cave inward as you stand up.",
                            bundle: .module, comment: "Band squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandSquat.easier", defaultValue: "Use a lighter band, or squat to a chair with no band.",
                           bundle: .module, comment: "Band squat: an easier version, as a short instruction")
        )
    }

    static var dumbbellRomanianDeadlift: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell Romanian deadlift", keyStem: "dumbbellRomanianDeadlift",
            displayName: String(localized: "exercise.dumbbellRomanianDeadlift.name", defaultValue: "Dumbbell Romanian deadlift",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellRomanianDeadlift.cue1", defaultValue: "Hold dumbbells in front of your thighs.",
                       bundle: .module, comment: "Dumbbell Romanian deadlift: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellRomanianDeadlift.cue2", defaultValue: "Soften your knees and push your hips back.",
                       bundle: .module, comment: "Dumbbell Romanian deadlift: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellRomanianDeadlift.cue3", defaultValue: "Slide the weights down your legs with your back flat.",
                       bundle: .module, comment: "Dumbbell Romanian deadlift: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellRomanianDeadlift.cue4", defaultValue: "Stop when you feel a stretch in your hamstrings.",
                       bundle: .module, comment: "Dumbbell Romanian deadlift: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellRomanianDeadlift.cue5", defaultValue: "Squeeze your glutes to stand back up.",
                       bundle: .module, comment: "Dumbbell Romanian deadlift: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellRomanianDeadlift.mistake", defaultValue: "Bending the knees deeply so it becomes a squat.",
                            bundle: .module, comment: "Dumbbell Romanian deadlift: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellRomanianDeadlift.easier", defaultValue: "Use lighter weights, and stop the weights at your knees.",
                           bundle: .module, comment: "Dumbbell Romanian deadlift: an easier version, as a short instruction")
        )
    }

    static var kettlebellDeadlift: ExerciseHowTo {
        ExerciseHowTo(
            name: "Kettlebell deadlift", keyStem: "kettlebellDeadlift",
            displayName: String(localized: "exercise.kettlebellDeadlift.name", defaultValue: "Kettlebell deadlift",
                                bundle: .module, comment: "Exercise name shown on screen (kettlebell exercise)"),
            cues: [
                String(localized: "exercise.kettlebellDeadlift.cue1", defaultValue: "Stand with the kettlebell between your feet.",
                       bundle: .module, comment: "Kettlebell deadlift: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.kettlebellDeadlift.cue2", defaultValue: "Push your hips back and grip the handle with a flat back.",
                       bundle: .module, comment: "Kettlebell deadlift: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.kettlebellDeadlift.cue3", defaultValue: "Stand up by driving your hips forward.",
                       bundle: .module, comment: "Kettlebell deadlift: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.kettlebellDeadlift.cue4", defaultValue: "Lower it by pushing your hips back again.",
                       bundle: .module, comment: "Kettlebell deadlift: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.kettlebellDeadlift.mistake", defaultValue: "Rounding the back to reach the kettlebell.",
                            bundle: .module, comment: "Kettlebell deadlift: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.kettlebellDeadlift.easier", defaultValue: "Use a lighter kettlebell, or raise it on a sturdy step.",
                           bundle: .module, comment: "Kettlebell deadlift: an easier version, as a short instruction")
        )
    }

    static var lateralBandWalk: ExerciseHowTo {
        ExerciseHowTo(
            name: "Lateral band walk", keyStem: "lateralBandWalk",
            displayName: String(localized: "exercise.lateralBandWalk.name", defaultValue: "Lateral band walk",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.lateralBandWalk.cue1", defaultValue: "Place a band around your legs, above your knees or ankles.",
                       bundle: .module, comment: "Lateral band walk: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.lateralBandWalk.cue2", defaultValue: "Bend your knees slightly into a half squat.",
                       bundle: .module, comment: "Lateral band walk: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.lateralBandWalk.cue3", defaultValue: "Step sideways, keeping tension on the band.",
                       bundle: .module, comment: "Lateral band walk: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.lateralBandWalk.cue4", defaultValue: "Keep your feet pointing forward and your hips level.",
                       bundle: .module, comment: "Lateral band walk: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.lateralBandWalk.cue5", defaultValue: "Walk one way, then come back the other way.",
                       bundle: .module, comment: "Lateral band walk: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.lateralBandWalk.mistake", defaultValue: "Letting the feet snap together so the band goes slack.",
                            bundle: .module, comment: "Lateral band walk: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.lateralBandWalk.easier", defaultValue: "Use a lighter band, or place it above your knees.",
                           bundle: .module, comment: "Lateral band walk: an easier version, as a short instruction")
        )
    }

    static var clamshell: ExerciseHowTo {
        ExerciseHowTo(
            name: "Clamshell", keyStem: "clamshell",
            displayName: String(localized: "exercise.clamshell.name", defaultValue: "Clamshell",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.clamshell.cue1", defaultValue: "Lie on your side with your knees bent and stacked.",
                       bundle: .module, comment: "Clamshell: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.clamshell.cue2", defaultValue: "Keep your feet together and your hips stacked.",
                       bundle: .module, comment: "Clamshell: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.clamshell.cue3", defaultValue: "Lift the top knee without rolling your hips back.",
                       bundle: .module, comment: "Clamshell: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.clamshell.cue4", defaultValue: "Lower it slowly, then switch sides after your reps.",
                       bundle: .module, comment: "Clamshell: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.clamshell.mistake", defaultValue: "Rolling the top hip backward to lift the knee higher.",
                            bundle: .module, comment: "Clamshell: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.clamshell.easier", defaultValue: "Lift the knee a smaller distance.",
                           bundle: .module, comment: "Clamshell: an easier version, as a short instruction")
        )
    }

    static var boxSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Box squat", keyStem: "boxSquat",
            displayName: String(localized: "exercise.boxSquat.name", defaultValue: "Box squat",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.boxSquat.cue1", defaultValue: "Stand just in front of a sturdy box or bench.",
                       bundle: .module, comment: "Box squat: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.boxSquat.cue2", defaultValue: "Set your feet a little wider than your hips.",
                       bundle: .module, comment: "Box squat: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.boxSquat.cue3", defaultValue: "Sit back until you lightly touch the box, chest tall.",
                       bundle: .module, comment: "Box squat: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.boxSquat.cue4", defaultValue: "Push through your whole foot to stand back up.",
                       bundle: .module, comment: "Box squat: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.boxSquat.mistake", defaultValue: "Dropping onto the box and rocking back to get up.",
                            bundle: .module, comment: "Box squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.boxSquat.easier", defaultValue: "Use a higher box, or hold a wall or rail for balance.",
                           bundle: .module, comment: "Box squat: an easier version, as a short instruction")
        )
    }

    static var wallSit: ExerciseHowTo {
        ExerciseHowTo(
            name: "Wall sit", keyStem: "wallSit",
            displayName: String(localized: "exercise.wallSit.name", defaultValue: "Wall sit",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.wallSit.cue1", defaultValue: "Lean your back flat against a wall.",
                       bundle: .module, comment: "Wall sit: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.wallSit.cue2", defaultValue: "Walk your feet forward and slide down the wall.",
                       bundle: .module, comment: "Wall sit: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.wallSit.cue3", defaultValue: "Stop with your knees above your ankles, thighs near level.",
                       bundle: .module, comment: "Wall sit: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.wallSit.cue4", defaultValue: "Feel it in the front of your thighs.",
                       bundle: .module, comment: "Wall sit: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.wallSit.cue5", defaultValue: "Breathe slowly and steadily, then slide back up to finish.",
                       bundle: .module, comment: "Wall sit: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.wallSit.mistake", defaultValue: "Letting the knees drift forward past the toes.",
                            bundle: .module, comment: "Wall sit: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.wallSit.easier", defaultValue: "Stay higher up the wall, and hold for less time.",
                           bundle: .module, comment: "Wall sit: an easier version, as a short instruction")
        )
    }

    static var dumbbellFrontSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell front squat", keyStem: "dumbbellFrontSquat",
            displayName: String(localized: "exercise.dumbbellFrontSquat.name", defaultValue: "Dumbbell front squat",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellFrontSquat.cue1", defaultValue: "Rest a dumbbell on each shoulder, elbows pointing forward.",
                       bundle: .module, comment: "Dumbbell front squat: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellFrontSquat.cue2", defaultValue: "Stand with your feet about shoulder-width apart.",
                       bundle: .module, comment: "Dumbbell front squat: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellFrontSquat.cue3", defaultValue: "Sit straight down, keeping your chest and elbows up.",
                       bundle: .module, comment: "Dumbbell front squat: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellFrontSquat.cue4", defaultValue: "Push through your whole foot to stand back up.",
                       bundle: .module, comment: "Dumbbell front squat: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellFrontSquat.mistake", defaultValue: "Letting the elbows drop so the chest tips forward.",
                            bundle: .module, comment: "Dumbbell front squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellFrontSquat.easier", defaultValue: "Do goblet squats with one weight held at your chest.",
                           bundle: .module, comment: "Dumbbell front squat: an easier version, as a short instruction")
        )
    }

    static var pistolSquatToBox: ExerciseHowTo {
        ExerciseHowTo(
            name: "Pistol squat to box", keyStem: "pistolSquatToBox",
            displayName: String(localized: "exercise.pistolSquatToBox.name", defaultValue: "Pistol squat to box",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.pistolSquatToBox.cue1", defaultValue: "Stand on one leg just in front of a box.",
                       bundle: .module, comment: "Pistol squat to box: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.pistolSquatToBox.cue2", defaultValue: "Reach your arms and your free leg forward.",
                       bundle: .module, comment: "Pistol squat to box: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.pistolSquatToBox.cue3", defaultValue: "Sit back slowly on one leg until you touch the box.",
                       bundle: .module, comment: "Pistol squat to box: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.pistolSquatToBox.cue4", defaultValue: "Keep your knee in line with your toes.",
                       bundle: .module, comment: "Pistol squat to box: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.pistolSquatToBox.cue5", defaultValue: "Push through your whole foot to stand, then switch legs.",
                       bundle: .module, comment: "Pistol squat to box: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.pistolSquatToBox.mistake", defaultValue: "Dropping onto the box instead of lowering with control.",
                            bundle: .module, comment: "Pistol squat to box: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.pistolSquatToBox.easier", defaultValue: "Use a higher box, or do box squats on both legs.",
                           bundle: .module, comment: "Pistol squat to box: an easier version, as a short instruction")
        )
    }

    static var smithMachineSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Smith machine squat", keyStem: "smithMachineSquat",
            displayName: String(localized: "exercise.smithMachineSquat.name", defaultValue: "Smith machine squat",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.smithMachineSquat.cue1", defaultValue: "Set the safety stops just below your lowest squat depth.",
                       bundle: .module, comment: "Smith machine squat: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.smithMachineSquat.cue2", defaultValue: "Rest the bar across your upper back, feet slightly forward.",
                       bundle: .module, comment: "Smith machine squat: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.smithMachineSquat.cue3", defaultValue: "Turn the bar to lift it off its hooks.",
                       bundle: .module, comment: "Smith machine squat: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.smithMachineSquat.cue4", defaultValue: "Squat down and up as the bar slides along its rails.",
                       bundle: .module, comment: "Smith machine squat: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.smithMachineSquat.cue5", defaultValue: "Turn the bar back onto the hooks when you finish.",
                       bundle: .module, comment: "Smith machine squat: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.smithMachineSquat.mistake", defaultValue: "Letting the heels lift or the knees cave inward.",
                            bundle: .module, comment: "Smith machine squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.smithMachineSquat.easier", defaultValue: "Use just the bar and stop higher, or do bodyweight squats.",
                           bundle: .module, comment: "Smith machine squat: an easier version, as a short instruction")
        )
    }

    static var splitSquat: ExerciseHowTo {
        ExerciseHowTo(
            name: "Split squat", keyStem: "splitSquat",
            displayName: String(localized: "exercise.splitSquat.name", defaultValue: "Split squat",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.splitSquat.cue1", defaultValue: "Stand in a long stride, one foot forward, one back.",
                       bundle: .module, comment: "Split squat: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.splitSquat.cue2", defaultValue: "Rise onto the ball of your back foot.",
                       bundle: .module, comment: "Split squat: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.splitSquat.cue3", defaultValue: "Lower straight down until your back knee nearly touches the floor.",
                       bundle: .module, comment: "Split squat: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.splitSquat.cue4", defaultValue: "Push through your front foot to rise, feet staying put.",
                       bundle: .module, comment: "Split squat: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.splitSquat.cue5", defaultValue: "Finish your reps, then switch legs.",
                       bundle: .module, comment: "Split squat: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.splitSquat.mistake", defaultValue: "Letting the front heel lift as you lower.",
                            bundle: .module, comment: "Split squat: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.splitSquat.easier", defaultValue: "Hold a wall or chair for balance, and lower only partway.",
                           bundle: .module, comment: "Split squat: an easier version, as a short instruction")
        )
    }

    static var sideLunge: ExerciseHowTo {
        ExerciseHowTo(
            name: "Side lunge", keyStem: "sideLunge",
            displayName: String(localized: "exercise.sideLunge.name", defaultValue: "Side lunge",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.sideLunge.cue1", defaultValue: "Stand tall with your feet together, hands at your chest.",
                       bundle: .module, comment: "Side lunge: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.sideLunge.cue2", defaultValue: "Take a wide step out to one side.",
                       bundle: .module, comment: "Side lunge: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.sideLunge.cue3", defaultValue: "Sit your hips back over that foot, other leg straight.",
                       bundle: .module, comment: "Side lunge: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.sideLunge.cue4", defaultValue: "Keep both feet flat and your chest tall.",
                       bundle: .module, comment: "Side lunge: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.sideLunge.cue5", defaultValue: "Push off the bent leg to bring your feet back together.",
                       bundle: .module, comment: "Side lunge: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.sideLunge.mistake", defaultValue: "Letting the bent knee drift inward or the heel lift.",
                            bundle: .module, comment: "Side lunge: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.sideLunge.easier", defaultValue: "Take a shorter step and lower only partway.",
                           bundle: .module, comment: "Side lunge: an easier version, as a short instruction")
        )
    }

    static var walkingLunge: ExerciseHowTo {
        ExerciseHowTo(
            name: "Walking lunge", keyStem: "walkingLunge",
            displayName: String(localized: "exercise.walkingLunge.name", defaultValue: "Walking lunge",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.walkingLunge.cue1", defaultValue: "Hold dumbbells at your sides and stand tall.",
                       bundle: .module, comment: "Walking lunge: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.walkingLunge.cue2", defaultValue: "Step forward and lower until your back knee nearly touches down.",
                       bundle: .module, comment: "Walking lunge: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.walkingLunge.cue3", defaultValue: "Keep your front knee in line with your toes.",
                       bundle: .module, comment: "Walking lunge: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.walkingLunge.cue4", defaultValue: "Push through your front foot and bring your back foot forward.",
                       bundle: .module, comment: "Walking lunge: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.walkingLunge.cue5", defaultValue: "Carry on into the next lunge with the other leg.",
                       bundle: .module, comment: "Walking lunge: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.walkingLunge.mistake", defaultValue: "Rushing forward so you wobble from side to side.",
                            bundle: .module, comment: "Walking lunge: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.walkingLunge.easier", defaultValue: "Skip the weights, or do reverse lunges in place.",
                           bundle: .module, comment: "Walking lunge: an easier version, as a short instruction")
        )
    }

    static var dumbbellSingleLegRomanianDeadlift: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell single-leg Romanian deadlift", keyStem: "dumbbellSingleLegRomanianDeadlift",
            displayName: String(localized: "exercise.dumbbellSingleLegRomanianDeadlift.name", defaultValue: "Dumbbell single-leg Romanian deadlift",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellSingleLegRomanianDeadlift.cue1", defaultValue: "Hold a dumbbell in the hand opposite your standing leg.",
                       bundle: .module, comment: "Dumbbell single-leg Romanian deadlift: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellSingleLegRomanianDeadlift.cue2", defaultValue: "Soften your standing knee and hinge forward at the hips.",
                       bundle: .module, comment: "Dumbbell single-leg Romanian deadlift: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellSingleLegRomanianDeadlift.cue3", defaultValue: "Let your free leg reach back as your chest lowers.",
                       bundle: .module, comment: "Dumbbell single-leg Romanian deadlift: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellSingleLegRomanianDeadlift.cue4", defaultValue: "Keep your hips square to the floor and your back flat.",
                       bundle: .module, comment: "Dumbbell single-leg Romanian deadlift: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellSingleLegRomanianDeadlift.cue5", defaultValue: "Squeeze your glutes to stand tall, then switch sides.",
                       bundle: .module, comment: "Dumbbell single-leg Romanian deadlift: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellSingleLegRomanianDeadlift.mistake", defaultValue: "Letting the free hip open up so the body twists.",
                            bundle: .module, comment: "Dumbbell single-leg Romanian deadlift: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellSingleLegRomanianDeadlift.easier", defaultValue: "Do the bodyweight single-leg deadlift, holding a wall for balance.",
                           bundle: .module, comment: "Dumbbell single-leg Romanian deadlift: an easier version, as a short instruction")
        )
    }

    static var bodyweightSingleLegDeadlift: ExerciseHowTo {
        ExerciseHowTo(
            name: "Bodyweight single-leg deadlift", keyStem: "bodyweightSingleLegDeadlift",
            displayName: String(localized: "exercise.bodyweightSingleLegDeadlift.name", defaultValue: "Bodyweight single-leg deadlift",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.bodyweightSingleLegDeadlift.cue1", defaultValue: "Stand on one leg with a soft bend in the knee.",
                       bundle: .module, comment: "Bodyweight single-leg deadlift: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightSingleLegDeadlift.cue2", defaultValue: "Hinge forward at the hips, hands reaching toward the floor.",
                       bundle: .module, comment: "Bodyweight single-leg deadlift: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightSingleLegDeadlift.cue3", defaultValue: "Lift your free leg behind you as your chest lowers.",
                       bundle: .module, comment: "Bodyweight single-leg deadlift: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightSingleLegDeadlift.cue4", defaultValue: "Keep your hips level and your back flat.",
                       bundle: .module, comment: "Bodyweight single-leg deadlift: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightSingleLegDeadlift.cue5", defaultValue: "Squeeze your glutes to stand, then switch legs.",
                       bundle: .module, comment: "Bodyweight single-leg deadlift: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bodyweightSingleLegDeadlift.mistake", defaultValue: "Rounding the back to reach the floor.",
                            bundle: .module, comment: "Bodyweight single-leg deadlift: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bodyweightSingleLegDeadlift.easier", defaultValue: "Hold a wall or chair for balance, and hinge only partway.",
                           bundle: .module, comment: "Bodyweight single-leg deadlift: an easier version, as a short instruction")
        )
    }

    static var bodyweightGoodMorning: ExerciseHowTo {
        ExerciseHowTo(
            name: "Bodyweight good morning", keyStem: "bodyweightGoodMorning",
            displayName: String(localized: "exercise.bodyweightGoodMorning.name", defaultValue: "Bodyweight good morning",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.bodyweightGoodMorning.cue1", defaultValue: "Stand with feet hip-width apart, hands lightly behind your head.",
                       bundle: .module, comment: "Bodyweight good morning: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightGoodMorning.cue2", defaultValue: "Soften your knees and keep your back flat.",
                       bundle: .module, comment: "Bodyweight good morning: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightGoodMorning.cue3", defaultValue: "Push your hips back and tip your chest forward.",
                       bundle: .module, comment: "Bodyweight good morning: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightGoodMorning.cue4", defaultValue: "Stop when you feel a stretch in your hamstrings.",
                       bundle: .module, comment: "Bodyweight good morning: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.bodyweightGoodMorning.cue5", defaultValue: "Drive your hips forward to stand tall again.",
                       bundle: .module, comment: "Bodyweight good morning: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bodyweightGoodMorning.mistake", defaultValue: "Rounding the back or bending the knees into a squat.",
                            bundle: .module, comment: "Bodyweight good morning: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bodyweightGoodMorning.easier", defaultValue: "Slide your hands down your thighs, and hinge only partway.",
                           bundle: .module, comment: "Bodyweight good morning: an easier version, as a short instruction")
        )
    }

    static var dumbbellGluteBridge: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell glute bridge", keyStem: "dumbbellGluteBridge",
            displayName: String(localized: "exercise.dumbbellGluteBridge.name", defaultValue: "Dumbbell glute bridge",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellGluteBridge.cue1", defaultValue: "Lie on your back, knees bent, feet flat near your hips.",
                       bundle: .module, comment: "Dumbbell glute bridge: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellGluteBridge.cue2", defaultValue: "Rest a dumbbell across your hips and hold it steady.",
                       bundle: .module, comment: "Dumbbell glute bridge: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellGluteBridge.cue3", defaultValue: "Push through your heels and lift your hips.",
                       bundle: .module, comment: "Dumbbell glute bridge: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.dumbbellGluteBridge.cue4", defaultValue: "Squeeze your glutes at the top, then lower slowly.",
                       bundle: .module, comment: "Dumbbell glute bridge: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellGluteBridge.mistake", defaultValue: "Lifting with the lower back instead of the glutes.",
                            bundle: .module, comment: "Dumbbell glute bridge: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellGluteBridge.easier", defaultValue: "Use a lighter dumbbell, or do the glute bridge with no weight.",
                           bundle: .module, comment: "Dumbbell glute bridge: an easier version, as a short instruction")
        )
    }

    static var dumbbellHipThrust: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell hip thrust", keyStem: "dumbbellHipThrust",
            displayName: String(localized: "exercise.dumbbellHipThrust.name", defaultValue: "Dumbbell hip thrust",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellHipThrust.cue1", defaultValue: "Sit with your upper back against the edge of a bench.",
                       bundle: .module, comment: "Dumbbell hip thrust: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellHipThrust.cue2", defaultValue: "Hold a dumbbell on your hips, feet flat and hip-width apart.",
                       bundle: .module, comment: "Dumbbell hip thrust: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellHipThrust.cue3", defaultValue: "Drive through your heels to lift your hips.",
                       bundle: .module, comment: "Dumbbell hip thrust: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellHipThrust.cue4", defaultValue: "Finish with your knees, hips and shoulders in a line.",
                       bundle: .module, comment: "Dumbbell hip thrust: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellHipThrust.cue5", defaultValue: "Keep your chin tucked and lower with control.",
                       bundle: .module, comment: "Dumbbell hip thrust: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellHipThrust.mistake", defaultValue: "Letting the knees fall inward as the hips rise.",
                            bundle: .module, comment: "Dumbbell hip thrust: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellHipThrust.easier", defaultValue: "Use a lighter dumbbell, or do glute bridges on the floor.",
                           bundle: .module, comment: "Dumbbell hip thrust: an easier version, as a short instruction")
        )
    }

    static var bandPullThrough: ExerciseHowTo {
        ExerciseHowTo(
            name: "Band pull-through", keyStem: "bandPullThrough",
            displayName: String(localized: "exercise.bandPullThrough.name", defaultValue: "Band pull-through",
                                bundle: .module, comment: "Exercise name shown on screen (resistance band exercise)"),
            cues: [
                String(localized: "exercise.bandPullThrough.cue1", defaultValue: "Anchor the band low behind you and face away from it.",
                       bundle: .module, comment: "Band pull-through: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bandPullThrough.cue2", defaultValue: "Hold it between your legs and walk out until it pulls.",
                       bundle: .module, comment: "Band pull-through: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bandPullThrough.cue3", defaultValue: "Push your hips back, letting the band draw your hands through.",
                       bundle: .module, comment: "Band pull-through: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bandPullThrough.cue4", defaultValue: "Squeeze your glutes to bring your hips forward and stand tall.",
                       bundle: .module, comment: "Band pull-through: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bandPullThrough.mistake", defaultValue: "Squatting down and pulling with the arms instead of hinging.",
                            bundle: .module, comment: "Band pull-through: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bandPullThrough.easier", defaultValue: "Use a lighter band, or stand closer to the anchor.",
                           bundle: .module, comment: "Band pull-through: an easier version, as a short instruction")
        )
    }

    static var singleLegCalfRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Single-leg calf raise", keyStem: "singleLegCalfRaise",
            displayName: String(localized: "exercise.singleLegCalfRaise.name", defaultValue: "Single-leg calf raise",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.singleLegCalfRaise.cue1", defaultValue: "Stand on one foot, holding a wall or rail for balance.",
                       bundle: .module, comment: "Single-leg calf raise: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.singleLegCalfRaise.cue2", defaultValue: "Rise as high as you can onto your toes.",
                       bundle: .module, comment: "Single-leg calf raise: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.singleLegCalfRaise.cue3", defaultValue: "Pause at the top, then lower your heel slowly.",
                       bundle: .module, comment: "Single-leg calf raise: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.singleLegCalfRaise.cue4", defaultValue: "Finish your reps, then switch feet.",
                       bundle: .module, comment: "Single-leg calf raise: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.singleLegCalfRaise.mistake", defaultValue: "Rolling onto the outer edge of the foot as you rise.",
                            bundle: .module, comment: "Single-leg calf raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.singleLegCalfRaise.easier", defaultValue: "Do calf raises on both feet, or rise only partway.",
                           bundle: .module, comment: "Single-leg calf raise: an easier version, as a short instruction")
        )
    }

    static var dumbbellSingleLegCalfRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dumbbell single-leg calf raise", keyStem: "dumbbellSingleLegCalfRaise",
            displayName: String(localized: "exercise.dumbbellSingleLegCalfRaise.name", defaultValue: "Dumbbell single-leg calf raise",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.dumbbellSingleLegCalfRaise.cue1", defaultValue: "Stand with the ball of one foot on a step edge.",
                       bundle: .module, comment: "Dumbbell single-leg calf raise: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellSingleLegCalfRaise.cue2", defaultValue: "Hold a dumbbell on that side, other hand on a wall.",
                       bundle: .module, comment: "Dumbbell single-leg calf raise: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellSingleLegCalfRaise.cue3", defaultValue: "Let your heel sink below the step for a gentle stretch.",
                       bundle: .module, comment: "Dumbbell single-leg calf raise: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellSingleLegCalfRaise.cue4", defaultValue: "Rise as high as you can, then lower slowly.",
                       bundle: .module, comment: "Dumbbell single-leg calf raise: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.dumbbellSingleLegCalfRaise.cue5", defaultValue: "Finish your reps, then switch sides.",
                       bundle: .module, comment: "Dumbbell single-leg calf raise: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.dumbbellSingleLegCalfRaise.mistake", defaultValue: "Bouncing at the bottom instead of moving smoothly.",
                            bundle: .module, comment: "Dumbbell single-leg calf raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.dumbbellSingleLegCalfRaise.easier", defaultValue: "Do it on flat ground, or do single-leg calf raises with no weight.",
                           bundle: .module, comment: "Dumbbell single-leg calf raise: an easier version, as a short instruction")
        )
    }

    static var cableGluteKickback: ExerciseHowTo {
        ExerciseHowTo(
            name: "Cable glute kickback", keyStem: "cableGluteKickback",
            displayName: String(localized: "exercise.cableGluteKickback.name", defaultValue: "Cable glute kickback",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.cableGluteKickback.cue1", defaultValue: "Strap one ankle to a low pulley and face the machine.",
                       bundle: .module, comment: "Cable glute kickback: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.cableGluteKickback.cue2", defaultValue: "Hold the frame and lean forward slightly, knees soft.",
                       bundle: .module, comment: "Cable glute kickback: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.cableGluteKickback.cue3", defaultValue: "Push the strapped leg back by squeezing your glute.",
                       bundle: .module, comment: "Cable glute kickback: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.cableGluteKickback.cue4", defaultValue: "Stop before your lower back arches, then return slowly.",
                       bundle: .module, comment: "Cable glute kickback: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.cableGluteKickback.cue5", defaultValue: "Finish your reps, then switch sides.",
                       bundle: .module, comment: "Cable glute kickback: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.cableGluteKickback.mistake", defaultValue: "Arching the lower back to swing the leg higher.",
                            bundle: .module, comment: "Cable glute kickback: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.cableGluteKickback.easier", defaultValue: "Use a lighter weight, or do donkey kicks on the floor.",
                           bundle: .module, comment: "Cable glute kickback: an easier version, as a short instruction")
        )
    }

    static var hipAbductionMachine: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hip abduction machine", keyStem: "hipAbductionMachine",
            displayName: String(localized: "exercise.hipAbductionMachine.name", defaultValue: "Hip abduction machine",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.hipAbductionMachine.cue1", defaultValue: "Sit tall with the pads on the outside of your knees.",
                       bundle: .module, comment: "Hip abduction machine: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.hipAbductionMachine.cue2", defaultValue: "Hold the handles and keep your back against the seat.",
                       bundle: .module, comment: "Hip abduction machine: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.hipAbductionMachine.cue3", defaultValue: "Push your knees apart as far as is comfortable.",
                       bundle: .module, comment: "Hip abduction machine: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.hipAbductionMachine.cue4", defaultValue: "Pause, then let your knees come back together slowly.",
                       bundle: .module, comment: "Hip abduction machine: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hipAbductionMachine.mistake", defaultValue: "Letting the weights crash down as the knees come back together.",
                            bundle: .module, comment: "Hip abduction machine: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hipAbductionMachine.easier", defaultValue: "Use a lighter weight, or do clamshells on the floor.",
                           bundle: .module, comment: "Hip abduction machine: an easier version, as a short instruction")
        )
    }

    static var hipAdductionMachine: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hip adduction machine", keyStem: "hipAdductionMachine",
            displayName: String(localized: "exercise.hipAdductionMachine.name", defaultValue: "Hip adduction machine",
                                bundle: .module, comment: "Exercise name shown on screen (machine exercise)"),
            cues: [
                String(localized: "exercise.hipAdductionMachine.cue1", defaultValue: "Sit tall with the pads on the inside of your knees.",
                       bundle: .module, comment: "Hip adduction machine: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.hipAdductionMachine.cue2", defaultValue: "Start with your legs only as wide as feels comfortable.",
                       bundle: .module, comment: "Hip adduction machine: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.hipAdductionMachine.cue3", defaultValue: "Squeeze your knees together until the pads meet.",
                       bundle: .module, comment: "Hip adduction machine: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.hipAdductionMachine.cue4", defaultValue: "Let your legs open slowly against the weight.",
                       bundle: .module, comment: "Hip adduction machine: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hipAdductionMachine.mistake", defaultValue: "Starting too wide and letting the weight yank the legs apart.",
                            bundle: .module, comment: "Hip adduction machine: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hipAdductionMachine.easier", defaultValue: "Use a lighter weight and a narrower starting position.",
                           bundle: .module, comment: "Hip adduction machine: an easier version, as a short instruction")
        )
    }

    static var cablePullThrough: ExerciseHowTo {
        ExerciseHowTo(
            name: "Cable pull-through", keyStem: "cablePullThrough",
            displayName: String(localized: "exercise.cablePullThrough.name", defaultValue: "Cable pull-through",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.cablePullThrough.cue1", defaultValue: "Set a rope on a low pulley and face away from it.",
                       bundle: .module, comment: "Cable pull-through: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.cablePullThrough.cue2", defaultValue: "Grip the rope between your legs and take two steps forward.",
                       bundle: .module, comment: "Cable pull-through: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.cablePullThrough.cue3", defaultValue: "Hinge at the hips, letting the rope draw your hands through.",
                       bundle: .module, comment: "Cable pull-through: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.cablePullThrough.cue4", defaultValue: "Squeeze your glutes to bring your hips forward and stand tall.",
                       bundle: .module, comment: "Cable pull-through: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.cablePullThrough.mistake", defaultValue: "Squatting down or pulling the rope with the arms instead of hinging.",
                            bundle: .module, comment: "Cable pull-through: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.cablePullThrough.easier", defaultValue: "Use a lighter weight, or do the band pull-through.",
                           bundle: .module, comment: "Cable pull-through: an easier version, as a short instruction")
        )
    }

    static var donkeyKick: ExerciseHowTo {
        ExerciseHowTo(
            name: "Donkey kick", keyStem: "donkeyKick",
            displayName: String(localized: "exercise.donkeyKick.name", defaultValue: "Donkey kick",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.donkeyKick.cue1", defaultValue: "Start on hands and knees, hands under your shoulders.",
                       bundle: .module, comment: "Donkey kick: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.donkeyKick.cue2", defaultValue: "Keep one knee bent at a right angle.",
                       bundle: .module, comment: "Donkey kick: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.donkeyKick.cue3", defaultValue: "Lift that foot toward the ceiling by squeezing your glute.",
                       bundle: .module, comment: "Donkey kick: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.donkeyKick.cue4", defaultValue: "Stop before your lower back arches, then lower slowly.",
                       bundle: .module, comment: "Donkey kick: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.donkeyKick.cue5", defaultValue: "Finish your reps, then switch sides.",
                       bundle: .module, comment: "Donkey kick: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.donkeyKick.mistake", defaultValue: "Swinging the leg up and letting the lower back sag.",
                            bundle: .module, comment: "Donkey kick: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.donkeyKick.easier", defaultValue: "Lift the foot only partway, or do glute bridges instead.",
                           bundle: .module, comment: "Donkey kick: an easier version, as a short instruction")
        )
    }
}
