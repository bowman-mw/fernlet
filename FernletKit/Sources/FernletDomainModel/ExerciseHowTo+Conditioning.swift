// ExerciseHowTo+Conditioning.swift
// FernletDomainModel — how-to text for the catalog's conditioning and power: cardio machines, jumps, throws and Olympic lifts.
//
// Fernlet-written, clean-room text (no website, dataset or book was copied or paraphrased),
// awaiting one review by a qualified coach before it ships. Every string is a catalog key under
// `exercise.<keyStem>.` resolved against `.module`; the English default here is what
// Scripts/sync-string-catalogs.sh harvests into Localizable.xcstrings, so edit both together.

import Foundation

extension ExerciseHowToCatalog {
    /// Conditioning and power: cardio machines, jumps, throws and Olympic lifts. In catalog order.
    static var conditioningEntries: [ExerciseHowTo] {
        [
            treadmillWalk,
            treadmillRun,
            burpee,
            kettlebellSwing,
            clean,
            snatch,
            thruster,
            turkishGetUp,
            mountainClimber,
            boxJump,
            broadJump,
            lateralBound,
            jumpRope,
            sprint,
            highKnees,
            medicineBallSlam,
            squatJump,
        ]
    }

    static var treadmillWalk: ExerciseHowTo {
        ExerciseHowTo(
            name: "Treadmill walk", keyStem: "treadmillWalk",
            displayName: String(localized: "exercise.treadmillWalk.name", defaultValue: "Treadmill walk",
                                bundle: .module, comment: "Exercise name shown on screen (cardio machine exercise)"),
            cues: [
                String(localized: "exercise.treadmillWalk.cue1", defaultValue: "Clip on the safety key and start at a slow speed.",
                       bundle: .module, comment: "Treadmill walk: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.treadmillWalk.cue2", defaultValue: "Stand tall and look ahead, not down at your feet.",
                       bundle: .module, comment: "Treadmill walk: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.treadmillWalk.cue3", defaultValue: "Let your arms swing naturally at your sides.",
                       bundle: .module, comment: "Treadmill walk: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.treadmillWalk.cue4", defaultValue: "Raise the speed or incline slowly until it feels brisk.",
                       bundle: .module, comment: "Treadmill walk: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.treadmillWalk.mistake", defaultValue: "Holding on to the rails, which changes how you walk.",
                            bundle: .module, comment: "Treadmill walk: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.treadmillWalk.easier", defaultValue: "Walk at a slower speed with no incline.",
                           bundle: .module, comment: "Treadmill walk: an easier version, as a short instruction")
        )
    }

    static var treadmillRun: ExerciseHowTo {
        ExerciseHowTo(
            name: "Treadmill run", keyStem: "treadmillRun",
            displayName: String(localized: "exercise.treadmillRun.name", defaultValue: "Treadmill run",
                                bundle: .module, comment: "Exercise name shown on screen (cardio machine exercise)"),
            cues: [
                String(localized: "exercise.treadmillRun.cue1", defaultValue: "Clip on the safety key and warm up with a walk.",
                       bundle: .module, comment: "Treadmill run: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.treadmillRun.cue2", defaultValue: "Raise the speed gradually to an easy running pace.",
                       bundle: .module, comment: "Treadmill run: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.treadmillRun.cue3", defaultValue: "Land softly with your feet under your body.",
                       bundle: .module, comment: "Treadmill run: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.treadmillRun.cue4", defaultValue: "Keep your shoulders relaxed and your arms bent.",
                       bundle: .module, comment: "Treadmill run: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.treadmillRun.cue5", defaultValue: "Slow down to a walk before stepping off.",
                       bundle: .module, comment: "Treadmill run: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.treadmillRun.mistake", defaultValue: "Starting too fast and overstriding with heavy heel landings.",
                            bundle: .module, comment: "Treadmill run: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.treadmillRun.easier", defaultValue: "Alternate one minute of easy jogging with one or two of walking.",
                           bundle: .module, comment: "Treadmill run: an easier version, as a short instruction")
        )
    }

    static var burpee: ExerciseHowTo {
        ExerciseHowTo(
            name: "Burpee", keyStem: "burpee",
            displayName: String(localized: "exercise.burpee.name", defaultValue: "Burpee",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.burpee.cue1", defaultValue: "Squat down and place your hands on the floor.",
                       bundle: .module, comment: "Burpee: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.burpee.cue2", defaultValue: "Step or jump your feet back into a plank.",
                       bundle: .module, comment: "Burpee: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.burpee.cue3", defaultValue: "Bring your feet back toward your hands.",
                       bundle: .module, comment: "Burpee: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.burpee.cue4", defaultValue: "Stand up, adding a small jump if you like.",
                       bundle: .module, comment: "Burpee: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.burpee.mistake", defaultValue: "Letting the hips sag in the plank as you tire.",
                            bundle: .module, comment: "Burpee: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.burpee.easier", defaultValue: "Step back and forward instead of jumping, and skip the jump at the top.",
                           bundle: .module, comment: "Burpee: an easier version, as a short instruction")
        )
    }

    static var kettlebellSwing: ExerciseHowTo {
        ExerciseHowTo(
            name: "Kettlebell swing", keyStem: "kettlebellSwing",
            displayName: String(localized: "exercise.kettlebellSwing.name", defaultValue: "Kettlebell swing",
                                bundle: .module, comment: "Exercise name shown on screen (kettlebell exercise)"),
            cues: [
                String(localized: "exercise.kettlebellSwing.cue1", defaultValue: "Stand with the kettlebell a little in front of your feet.",
                       bundle: .module, comment: "Kettlebell swing: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.kettlebellSwing.cue2", defaultValue: "Hinge and hike the kettlebell back between your legs.",
                       bundle: .module, comment: "Kettlebell swing: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.kettlebellSwing.cue3", defaultValue: "Snap your hips forward to float it to chest height.",
                       bundle: .module, comment: "Kettlebell swing: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.kettlebellSwing.cue4", defaultValue: "Keep your arms loose; your hips do the work.",
                       bundle: .module, comment: "Kettlebell swing: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.kettlebellSwing.cue5", defaultValue: "Let it fall back and hinge again as it comes down.",
                       bundle: .module, comment: "Kettlebell swing: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.kettlebellSwing.mistake", defaultValue: "Squatting down and lifting the kettlebell with the arms instead of the hips.",
                            bundle: .module, comment: "Kettlebell swing: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.kettlebellSwing.easier", defaultValue: "Practice the hinge with kettlebell deadlifts, then swing a lighter kettlebell.",
                           bundle: .module, comment: "Kettlebell swing: an easier version, as a short instruction")
        )
    }

    static var clean: ExerciseHowTo {
        ExerciseHowTo(
            name: "Clean", keyStem: "clean",
            displayName: String(localized: "exercise.clean.name", defaultValue: "Clean",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.clean.cue1", defaultValue: "Learn it with a coach, or with an empty bar first.",
                       bundle: .module, comment: "Clean: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.clean.cue2", defaultValue: "Start like a deadlift, bar over mid-foot, back flat.",
                       bundle: .module, comment: "Clean: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.clean.cue3", defaultValue: "Lift the bar past your knees, keeping it close.",
                       bundle: .module, comment: "Clean: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.clean.cue4", defaultValue: "Jump with your hips and pull yourself under the bar.",
                       bundle: .module, comment: "Clean: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.clean.cue5", defaultValue: "Catch it on your front shoulders with your elbows high.",
                       bundle: .module, comment: "Clean: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.clean.mistake", defaultValue: "Pulling early with the arms instead of driving with the legs and hips.",
                            bundle: .module, comment: "Clean: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.clean.easier", defaultValue: "Do dumbbell or kettlebell cleans, or start from above the knees.",
                           bundle: .module, comment: "Clean: an easier version, as a short instruction")
        )
    }

    static var snatch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Snatch", keyStem: "snatch",
            displayName: String(localized: "exercise.snatch.name", defaultValue: "Snatch",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.snatch.cue1", defaultValue: "Learn it with a coach, or with a light bar first.",
                       bundle: .module, comment: "Snatch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.snatch.cue2", defaultValue: "Take a wide grip with the bar over your mid-foot.",
                       bundle: .module, comment: "Snatch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.snatch.cue3", defaultValue: "Lift the bar close to your body past your knees.",
                       bundle: .module, comment: "Snatch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.snatch.cue4", defaultValue: "Drive up through your hips and pull yourself under the bar.",
                       bundle: .module, comment: "Snatch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.snatch.cue5", defaultValue: "Catch it overhead with locked arms in a squat.",
                       bundle: .module, comment: "Snatch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.snatch.mistake", defaultValue: "Letting the bar swing out away from the body.",
                            bundle: .module, comment: "Snatch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.snatch.easier", defaultValue: "Do a one-arm dumbbell snatch, or practice with a broomstick.",
                           bundle: .module, comment: "Snatch: an easier version, as a short instruction")
        )
    }

    static var thruster: ExerciseHowTo {
        ExerciseHowTo(
            name: "Thruster", keyStem: "thruster",
            displayName: String(localized: "exercise.thruster.name", defaultValue: "Thruster",
                                bundle: .module, comment: "Exercise name shown on screen (barbell exercise)"),
            cues: [
                String(localized: "exercise.thruster.cue1", defaultValue: "Hold the bar on your front shoulders, elbows up.",
                       bundle: .module, comment: "Thruster: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.thruster.cue2", defaultValue: "Squat down with your chest tall.",
                       bundle: .module, comment: "Thruster: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.thruster.cue3", defaultValue: "Drive up hard and use that push to press overhead.",
                       bundle: .module, comment: "Thruster: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.thruster.cue4", defaultValue: "Finish with your arms straight and the bar over your head.",
                       bundle: .module, comment: "Thruster: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.thruster.cue5", defaultValue: "Lower the bar to your shoulders as you squat again.",
                       bundle: .module, comment: "Thruster: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.thruster.mistake", defaultValue: "Pausing between the squat and the press, which loses the leg drive.",
                            bundle: .module, comment: "Thruster: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.thruster.easier", defaultValue: "Use light dumbbells, or do the squat and press as separate moves.",
                           bundle: .module, comment: "Thruster: an easier version, as a short instruction")
        )
    }

    static var turkishGetUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Turkish get-up", keyStem: "turkishGetUp",
            displayName: String(localized: "exercise.turkishGetUp.name", defaultValue: "Turkish get-up",
                                bundle: .module, comment: "Exercise name shown on screen (kettlebell exercise)"),
            cues: [
                String(localized: "exercise.turkishGetUp.cue1", defaultValue: "Lie down holding the kettlebell straight up over your shoulder.",
                       bundle: .module, comment: "Turkish get-up: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.turkishGetUp.cue2", defaultValue: "Keep your eyes on the kettlebell the whole way.",
                       bundle: .module, comment: "Turkish get-up: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.turkishGetUp.cue3", defaultValue: "Roll to your elbow, then your hand, then lift your hips.",
                       bundle: .module, comment: "Turkish get-up: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.turkishGetUp.cue4", defaultValue: "Sweep your leg under you to kneel, then stand up.",
                       bundle: .module, comment: "Turkish get-up: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.turkishGetUp.cue5", defaultValue: "Reverse each step slowly to lie back down.",
                       bundle: .module, comment: "Turkish get-up: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.turkishGetUp.mistake", defaultValue: "Rushing through the steps and letting the arm drift off vertical.",
                            bundle: .module, comment: "Turkish get-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.turkishGetUp.easier", defaultValue: "Practice the steps with no weight, or with a shoe balanced on your fist.",
                           bundle: .module, comment: "Turkish get-up: an easier version, as a short instruction")
        )
    }

    static var mountainClimber: ExerciseHowTo {
        ExerciseHowTo(
            name: "Mountain climber", keyStem: "mountainClimber",
            displayName: String(localized: "exercise.mountainClimber.name", defaultValue: "Mountain climber",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.mountainClimber.cue1", defaultValue: "Start in a high plank with your hands under your shoulders.",
                       bundle: .module, comment: "Mountain climber: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.mountainClimber.cue2", defaultValue: "Drive one knee toward your chest.",
                       bundle: .module, comment: "Mountain climber: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.mountainClimber.cue3", defaultValue: "Switch legs in a steady rhythm.",
                       bundle: .module, comment: "Mountain climber: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.mountainClimber.cue4", defaultValue: "Keep your hips low and your back flat.",
                       bundle: .module, comment: "Mountain climber: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.mountainClimber.mistake", defaultValue: "Lifting the hips high and bouncing the whole body.",
                            bundle: .module, comment: "Mountain climber: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.mountainClimber.easier", defaultValue: "Step each foot in slowly, or put your hands on a bench.",
                           bundle: .module, comment: "Mountain climber: an easier version, as a short instruction")
        )
    }

    static var boxJump: ExerciseHowTo {
        ExerciseHowTo(
            name: "Box jump", keyStem: "boxJump",
            displayName: String(localized: "exercise.boxJump.name", defaultValue: "Box jump",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.boxJump.cue1", defaultValue: "Stand close to a sturdy box of a modest height.",
                       bundle: .module, comment: "Box jump: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.boxJump.cue2", defaultValue: "Swing your arms back and dip your hips.",
                       bundle: .module, comment: "Box jump: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.boxJump.cue3", defaultValue: "Jump up and land softly with both feet on the box.",
                       bundle: .module, comment: "Box jump: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.boxJump.cue4", defaultValue: "Stand up tall on top, then step down.",
                       bundle: .module, comment: "Box jump: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.boxJump.mistake", defaultValue: "Jumping back down instead of stepping down.",
                            bundle: .module, comment: "Box jump: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.boxJump.easier", defaultValue: "Use a lower box, or do squat jumps on the floor.",
                           bundle: .module, comment: "Box jump: an easier version, as a short instruction")
        )
    }

    static var broadJump: ExerciseHowTo {
        ExerciseHowTo(
            name: "Broad jump", keyStem: "broadJump",
            displayName: String(localized: "exercise.broadJump.name", defaultValue: "Broad jump",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.broadJump.cue1", defaultValue: "Stand with your feet hip-width apart.",
                       bundle: .module, comment: "Broad jump: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.broadJump.cue2", defaultValue: "Swing your arms back and bend your hips and knees.",
                       bundle: .module, comment: "Broad jump: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.broadJump.cue3", defaultValue: "Swing your arms forward and jump out.",
                       bundle: .module, comment: "Broad jump: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.broadJump.cue4", defaultValue: "Land softly on both feet with your knees bent.",
                       bundle: .module, comment: "Broad jump: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.broadJump.cue5", defaultValue: "Hold the landing, then walk back to reset.",
                       bundle: .module, comment: "Broad jump: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.broadJump.mistake", defaultValue: "Landing stiff-legged with the knees caving inward.",
                            bundle: .module, comment: "Broad jump: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.broadJump.easier", defaultValue: "Jump a shorter distance, or practice soft landings from a small hop.",
                           bundle: .module, comment: "Broad jump: an easier version, as a short instruction")
        )
    }

    static var lateralBound: ExerciseHowTo {
        ExerciseHowTo(
            name: "Lateral bound", keyStem: "lateralBound",
            displayName: String(localized: "exercise.lateralBound.name", defaultValue: "Lateral bound",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.lateralBound.cue1", defaultValue: "Stand on one leg with a slight bend in the knee.",
                       bundle: .module, comment: "Lateral bound: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.lateralBound.cue2", defaultValue: "Push off sideways and land on the other foot.",
                       bundle: .module, comment: "Lateral bound: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.lateralBound.cue3", defaultValue: "Land softly and hold still for a moment.",
                       bundle: .module, comment: "Lateral bound: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.lateralBound.cue4", defaultValue: "Keep your landing knee in line with your toes.",
                       bundle: .module, comment: "Lateral bound: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.lateralBound.mistake", defaultValue: "Landing with the knee falling inward.",
                            bundle: .module, comment: "Lateral bound: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.lateralBound.easier", defaultValue: "Take smaller hops, or step side to side instead of jumping.",
                           bundle: .module, comment: "Lateral bound: an easier version, as a short instruction")
        )
    }

    static var jumpRope: ExerciseHowTo {
        ExerciseHowTo(
            name: "Jump rope", keyStem: "jumpRope",
            displayName: String(localized: "exercise.jumpRope.name", defaultValue: "Jump rope",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.jumpRope.cue1", defaultValue: "Hold the handles at hip height, elbows close to your body.",
                       bundle: .module, comment: "Jump rope: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.jumpRope.cue2", defaultValue: "Turn the rope with your wrists, not your arms.",
                       bundle: .module, comment: "Jump rope: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.jumpRope.cue3", defaultValue: "Jump just high enough to clear the rope.",
                       bundle: .module, comment: "Jump rope: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.jumpRope.cue4", defaultValue: "Land softly on the balls of your feet.",
                       bundle: .module, comment: "Jump rope: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.jumpRope.mistake", defaultValue: "Jumping too high and landing hard on the heels.",
                            bundle: .module, comment: "Jump rope: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.jumpRope.easier", defaultValue: "Practice the jumping rhythm without the rope.",
                           bundle: .module, comment: "Jump rope: an easier version, as a short instruction")
        )
    }

    static var sprint: ExerciseHowTo {
        ExerciseHowTo(
            name: "Sprint", keyStem: "sprint",
            displayName: String(localized: "exercise.sprint.name", defaultValue: "Sprint",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.sprint.cue1", defaultValue: "Warm up first with easy jogging and a few short build-ups.",
                       bundle: .module, comment: "Sprint: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.sprint.cue2", defaultValue: "Lean forward slightly and drive your knees up.",
                       bundle: .module, comment: "Sprint: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.sprint.cue3", defaultValue: "Pump your arms from your shoulders.",
                       bundle: .module, comment: "Sprint: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.sprint.cue4", defaultValue: "Keep your face and hands relaxed.",
                       bundle: .module, comment: "Sprint: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.sprint.cue5", defaultValue: "Slow down gradually after each effort.",
                       bundle: .module, comment: "Sprint: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.sprint.mistake", defaultValue: "Sprinting flat out without warming up first.",
                            bundle: .module, comment: "Sprint: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.sprint.easier", defaultValue: "Run strides at about three-quarters of your top speed.",
                           bundle: .module, comment: "Sprint: an easier version, as a short instruction")
        )
    }

    static var highKnees: ExerciseHowTo {
        ExerciseHowTo(
            name: "High knees", keyStem: "highKnees",
            displayName: String(localized: "exercise.highKnees.name", defaultValue: "High knees",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.highKnees.cue1", defaultValue: "Stand tall and jog in place.",
                       bundle: .module, comment: "High knees: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.highKnees.cue2", defaultValue: "Lift your knees toward hip height.",
                       bundle: .module, comment: "High knees: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.highKnees.cue3", defaultValue: "Land softly on the balls of your feet.",
                       bundle: .module, comment: "High knees: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.highKnees.cue4", defaultValue: "Pump your arms in time with your legs.",
                       bundle: .module, comment: "High knees: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.highKnees.mistake", defaultValue: "Leaning back as the knees come up.",
                            bundle: .module, comment: "High knees: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.highKnees.easier", defaultValue: "March in place, lifting each knee without jumping.",
                           bundle: .module, comment: "High knees: an easier version, as a short instruction")
        )
    }

    static var medicineBallSlam: ExerciseHowTo {
        ExerciseHowTo(
            name: "Medicine ball slam", keyStem: "medicineBallSlam",
            displayName: String(localized: "exercise.medicineBallSlam.name", defaultValue: "Medicine ball slam",
                                bundle: .module, comment: "Exercise name shown on screen (exercise)"),
            cues: [
                String(localized: "exercise.medicineBallSlam.cue1", defaultValue: "Use a ball made for slamming, one that won't bounce back.",
                       bundle: .module, comment: "Medicine ball slam: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.medicineBallSlam.cue2", defaultValue: "Lift the ball overhead, rising onto your toes.",
                       bundle: .module, comment: "Medicine ball slam: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.medicineBallSlam.cue3", defaultValue: "Slam it down in front of you, hinging at the hips.",
                       bundle: .module, comment: "Medicine ball slam: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.medicineBallSlam.cue4", defaultValue: "Squat to pick it up with a flat back.",
                       bundle: .module, comment: "Medicine ball slam: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.medicineBallSlam.mistake", defaultValue: "Rounding the back to scoop the ball up off the floor.",
                            bundle: .module, comment: "Medicine ball slam: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.medicineBallSlam.easier", defaultValue: "Use a lighter ball and slam with less force.",
                           bundle: .module, comment: "Medicine ball slam: an easier version, as a short instruction")
        )
    }

    static var squatJump: ExerciseHowTo {
        ExerciseHowTo(
            name: "Squat jump", keyStem: "squatJump",
            displayName: String(localized: "exercise.squatJump.name", defaultValue: "Squat jump",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.squatJump.cue1", defaultValue: "Stand with your feet shoulder-width apart.",
                       bundle: .module, comment: "Squat jump: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.squatJump.cue2", defaultValue: "Squat to a comfortable depth with your arms back.",
                       bundle: .module, comment: "Squat jump: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.squatJump.cue3", defaultValue: "Jump straight up, swinging your arms.",
                       bundle: .module, comment: "Squat jump: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.squatJump.cue4", defaultValue: "Land softly with bent knees, then reset.",
                       bundle: .module, comment: "Squat jump: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.squatJump.mistake", defaultValue: "Landing with stiff legs and the knees caving in.",
                            bundle: .module, comment: "Squat jump: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.squatJump.easier", defaultValue: "Do bodyweight squats, rising onto your toes at the top.",
                           bundle: .module, comment: "Squat jump: an easier version, as a short instruction")
        )
    }
}
