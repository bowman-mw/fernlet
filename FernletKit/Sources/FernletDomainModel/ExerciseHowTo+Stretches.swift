// ExerciseHowTo+Stretches.swift
// FernletDomainModel — how-to text for the catalog's the warm-up and cool-down stretches.
//
// Fernlet-written, clean-room text (no website, dataset or book was copied or paraphrased),
// awaiting one review by a qualified coach before it ships. Every string is a catalog key under
// `exercise.<keyStem>.` resolved against `.module`; the English default here is what
// Scripts/sync-string-catalogs.sh harvests into Localizable.xcstrings, so edit both together.

import Foundation

extension ExerciseHowToCatalog {
    /// The warm-up and cool-down stretches. In catalog order.
    static var stretchEntries: [ExerciseHowTo] {
        [
            standingForwardFold,
            lowLungeStretch,
            sideLungeStretch,
            lyingHamstringStretch,
            butterflyStretch,
            catCow,
            downwardDog,
            childsPose,
            standingQuadStretch,
            wideLegForwardFold,
            crossBodyShoulderStretch,
            overheadTricepsStretch,
            figureFourStretch,
            doorwayChestStretch,
            calfStretch,
            threadTheNeedle,
            supineTwist,
            neckSideStretch,
            cobraStretch,
            kneeToChestStretch,
            pigeonStretch,
            seatedHamstringStretch,
            wristCircles,
            upperBackFoamRoll,
            legSwings,
        ]
    }

    static var standingForwardFold: ExerciseHowTo {
        ExerciseHowTo(
            name: "Standing forward fold", keyStem: "standingForwardFold",
            displayName: String(localized: "exercise.standingForwardFold.name", defaultValue: "Standing forward fold",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.standingForwardFold.cue1", defaultValue: "Stand with your feet hip-width apart and knees soft.",
                       bundle: .module, comment: "Standing forward fold: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.standingForwardFold.cue2", defaultValue: "Fold forward from your hips and let your arms hang.",
                       bundle: .module, comment: "Standing forward fold: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.standingForwardFold.cue3", defaultValue: "Feel the stretch along the backs of your legs.",
                       bundle: .module, comment: "Standing forward fold: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.standingForwardFold.cue4", defaultValue: "Breathe out slowly and let your body sink a little.",
                       bundle: .module, comment: "Standing forward fold: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.standingForwardFold.cue5", defaultValue: "Roll up slowly to stand when you're done.",
                       bundle: .module, comment: "Standing forward fold: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.standingForwardFold.mistake", defaultValue: "Bouncing to reach the floor.",
                            bundle: .module, comment: "Standing forward fold: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.standingForwardFold.easier", defaultValue: "Bend your knees more, or rest your hands on a chair.",
                           bundle: .module, comment: "Standing forward fold: an easier version, as a short instruction")
        )
    }

    static var lowLungeStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Low lunge stretch", keyStem: "lowLungeStretch",
            displayName: String(localized: "exercise.lowLungeStretch.name", defaultValue: "Low lunge stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.lowLungeStretch.cue1", defaultValue: "Kneel on one knee with the other foot flat in front.",
                       bundle: .module, comment: "Low lunge stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.lowLungeStretch.cue2", defaultValue: "Tuck your hips under slightly.",
                       bundle: .module, comment: "Low lunge stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.lowLungeStretch.cue3", defaultValue: "Shift forward gently, keeping your torso upright.",
                       bundle: .module, comment: "Low lunge stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.lowLungeStretch.cue4", defaultValue: "Feel the stretch at the front of your back hip and thigh.",
                       bundle: .module, comment: "Low lunge stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.lowLungeStretch.cue5", defaultValue: "Breathe slowly and ease a little deeper as you breathe out.",
                       bundle: .module, comment: "Low lunge stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.lowLungeStretch.mistake", defaultValue: "Arching the lower back instead of tucking the hips.",
                            bundle: .module, comment: "Low lunge stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.lowLungeStretch.easier", defaultValue: "Put a cushion under your knee, or hold a chair for balance.",
                           bundle: .module, comment: "Low lunge stretch: an easier version, as a short instruction")
        )
    }

    static var sideLungeStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Side lunge stretch", keyStem: "sideLungeStretch",
            displayName: String(localized: "exercise.sideLungeStretch.name", defaultValue: "Side lunge stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.sideLungeStretch.cue1", defaultValue: "Stand with your feet wide and toes forward.",
                       bundle: .module, comment: "Side lunge stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.sideLungeStretch.cue2", defaultValue: "Bend one knee and shift your hips toward it.",
                       bundle: .module, comment: "Side lunge stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.sideLungeStretch.cue3", defaultValue: "Keep the other leg straight, foot flat.",
                       bundle: .module, comment: "Side lunge stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.sideLungeStretch.cue4", defaultValue: "Feel the stretch along the inner thigh of the straight leg.",
                       bundle: .module, comment: "Side lunge stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.sideLungeStretch.cue5", defaultValue: "Breathe steadily, then switch sides.",
                       bundle: .module, comment: "Side lunge stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.sideLungeStretch.mistake", defaultValue: "Letting the bent knee drift inward.",
                            bundle: .module, comment: "Side lunge stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.sideLungeStretch.easier", defaultValue: "Take a narrower stance and bend the knee less.",
                           bundle: .module, comment: "Side lunge stretch: an easier version, as a short instruction")
        )
    }

    static var lyingHamstringStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Lying hamstring stretch", keyStem: "lyingHamstringStretch",
            displayName: String(localized: "exercise.lyingHamstringStretch.name", defaultValue: "Lying hamstring stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.lyingHamstringStretch.cue1", defaultValue: "Lie on your back with both legs straight.",
                       bundle: .module, comment: "Lying hamstring stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.lyingHamstringStretch.cue2", defaultValue: "Lift one leg, holding behind the thigh or using a strap.",
                       bundle: .module, comment: "Lying hamstring stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.lyingHamstringStretch.cue3", defaultValue: "Keep a slight bend in the knee.",
                       bundle: .module, comment: "Lying hamstring stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.lyingHamstringStretch.cue4", defaultValue: "Feel the stretch along the back of the raised thigh.",
                       bundle: .module, comment: "Lying hamstring stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.lyingHamstringStretch.cue5", defaultValue: "Breathe out slowly and let the leg drift closer.",
                       bundle: .module, comment: "Lying hamstring stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.lyingHamstringStretch.mistake", defaultValue: "Pulling the leg hard with a rounded back and lifted head.",
                            bundle: .module, comment: "Lying hamstring stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.lyingHamstringStretch.easier", defaultValue: "Bend the other knee with your foot flat on the floor.",
                           bundle: .module, comment: "Lying hamstring stretch: an easier version, as a short instruction")
        )
    }

    static var butterflyStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Butterfly stretch", keyStem: "butterflyStretch",
            displayName: String(localized: "exercise.butterflyStretch.name", defaultValue: "Butterfly stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.butterflyStretch.cue1", defaultValue: "Sit tall with the soles of your feet together.",
                       bundle: .module, comment: "Butterfly stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.butterflyStretch.cue2", defaultValue: "Hold your ankles and let your knees fall open.",
                       bundle: .module, comment: "Butterfly stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.butterflyStretch.cue3", defaultValue: "Lean forward slightly from your hips, back long.",
                       bundle: .module, comment: "Butterfly stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.butterflyStretch.cue4", defaultValue: "Feel the stretch in your inner thighs.",
                       bundle: .module, comment: "Butterfly stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.butterflyStretch.cue5", defaultValue: "Breathe slowly and let your knees sink as you breathe out.",
                       bundle: .module, comment: "Butterfly stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.butterflyStretch.mistake", defaultValue: "Pushing the knees down hard with the hands.",
                            bundle: .module, comment: "Butterfly stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.butterflyStretch.easier", defaultValue: "Move your feet farther from your body, or sit on a cushion.",
                           bundle: .module, comment: "Butterfly stretch: an easier version, as a short instruction")
        )
    }

    static var catCow: ExerciseHowTo {
        ExerciseHowTo(
            name: "Cat-cow", keyStem: "catCow",
            displayName: String(localized: "exercise.catCow.name", defaultValue: "Cat-cow",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.catCow.cue1", defaultValue: "Start on hands and knees, hands under your shoulders.",
                       bundle: .module, comment: "Cat-cow: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.catCow.cue2", defaultValue: "Breathe in as you drop your belly and lift your gaze.",
                       bundle: .module, comment: "Cat-cow: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.catCow.cue3", defaultValue: "Breathe out as you round your back toward the ceiling.",
                       bundle: .module, comment: "Cat-cow: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.catCow.cue4", defaultValue: "Feel your spine move one section at a time.",
                       bundle: .module, comment: "Cat-cow: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.catCow.cue5", defaultValue: "Move slowly, matching each movement to a breath.",
                       bundle: .module, comment: "Cat-cow: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.catCow.mistake", defaultValue: "Rushing through the movement without matching it to your breath.",
                            bundle: .module, comment: "Cat-cow: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.catCow.easier", defaultValue: "Do it sitting on a chair with your hands on your knees.",
                           bundle: .module, comment: "Cat-cow: an easier version, as a short instruction")
        )
    }

    static var downwardDog: ExerciseHowTo {
        ExerciseHowTo(
            name: "Downward dog", keyStem: "downwardDog",
            displayName: String(localized: "exercise.downwardDog.name", defaultValue: "Downward dog",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.downwardDog.cue1", defaultValue: "Start on hands and knees, then lift your hips up and back.",
                       bundle: .module, comment: "Downward dog: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.downwardDog.cue2", defaultValue: "Spread your fingers and press the floor away.",
                       bundle: .module, comment: "Downward dog: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.downwardDog.cue3", defaultValue: "Bend your knees as needed to keep your back long.",
                       bundle: .module, comment: "Downward dog: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.downwardDog.cue4", defaultValue: "Feel the stretch through the backs of your legs and shoulders.",
                       bundle: .module, comment: "Downward dog: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.downwardDog.cue5", defaultValue: "Breathe slowly and let your heels sink toward the floor.",
                       bundle: .module, comment: "Downward dog: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.downwardDog.mistake", defaultValue: "Forcing the heels down so the back rounds.",
                            bundle: .module, comment: "Downward dog: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.downwardDog.easier", defaultValue: "Put your hands on a chair or wall instead of the floor.",
                           bundle: .module, comment: "Downward dog: an easier version, as a short instruction")
        )
    }

    static var childsPose: ExerciseHowTo {
        ExerciseHowTo(
            name: "Child's pose", keyStem: "childsPose",
            displayName: String(localized: "exercise.childsPose.name", defaultValue: "Child's pose",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.childsPose.cue1", defaultValue: "Kneel and sit back toward your heels.",
                       bundle: .module, comment: "Child's pose: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.childsPose.cue2", defaultValue: "Fold forward and rest your forehead down.",
                       bundle: .module, comment: "Child's pose: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.childsPose.cue3", defaultValue: "Reach your arms forward or rest them by your sides.",
                       bundle: .module, comment: "Child's pose: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.childsPose.cue4", defaultValue: "Feel your back and the sides of your ribs lengthen.",
                       bundle: .module, comment: "Child's pose: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.childsPose.cue5", defaultValue: "Breathe slowly into your back.",
                       bundle: .module, comment: "Child's pose: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.childsPose.mistake", defaultValue: "Forcing the hips down onto the heels when they don't reach.",
                            bundle: .module, comment: "Child's pose: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.childsPose.easier", defaultValue: "Put a pillow between your hips and heels, or under your chest.",
                           bundle: .module, comment: "Child's pose: an easier version, as a short instruction")
        )
    }

    static var standingQuadStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Standing quad stretch", keyStem: "standingQuadStretch",
            displayName: String(localized: "exercise.standingQuadStretch.name", defaultValue: "Standing quad stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.standingQuadStretch.cue1", defaultValue: "Stand tall, holding a wall or chair for balance.",
                       bundle: .module, comment: "Standing quad stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.standingQuadStretch.cue2", defaultValue: "Bend one knee and hold that ankle behind you.",
                       bundle: .module, comment: "Standing quad stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.standingQuadStretch.cue3", defaultValue: "Keep your knees close together and your hips tucked under.",
                       bundle: .module, comment: "Standing quad stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.standingQuadStretch.cue4", defaultValue: "Feel the stretch along the front of your thigh.",
                       bundle: .module, comment: "Standing quad stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.standingQuadStretch.cue5", defaultValue: "Breathe steadily, then switch legs.",
                       bundle: .module, comment: "Standing quad stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.standingQuadStretch.mistake", defaultValue: "Arching the back and letting the knee drift out to the side.",
                            bundle: .module, comment: "Standing quad stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.standingQuadStretch.easier", defaultValue: "Loop a strap or towel around your ankle, or do it lying on your side.",
                           bundle: .module, comment: "Standing quad stretch: an easier version, as a short instruction")
        )
    }

    static var wideLegForwardFold: ExerciseHowTo {
        ExerciseHowTo(
            name: "Wide-leg forward fold", keyStem: "wideLegForwardFold",
            displayName: String(localized: "exercise.wideLegForwardFold.name", defaultValue: "Wide-leg forward fold",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.wideLegForwardFold.cue1", defaultValue: "Stand with your feet wide apart and toes forward.",
                       bundle: .module, comment: "Wide-leg forward fold: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.wideLegForwardFold.cue2", defaultValue: "Hinge forward from your hips with a long back.",
                       bundle: .module, comment: "Wide-leg forward fold: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.wideLegForwardFold.cue3", defaultValue: "Rest your hands on the floor, a block or your legs.",
                       bundle: .module, comment: "Wide-leg forward fold: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.wideLegForwardFold.cue4", defaultValue: "Feel the stretch in your hamstrings and inner thighs.",
                       bundle: .module, comment: "Wide-leg forward fold: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.wideLegForwardFold.cue5", defaultValue: "Breathe slowly, folding a little more as you breathe out.",
                       bundle: .module, comment: "Wide-leg forward fold: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.wideLegForwardFold.mistake", defaultValue: "Rounding the upper back to get the head lower.",
                            bundle: .module, comment: "Wide-leg forward fold: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.wideLegForwardFold.easier", defaultValue: "Bend your knees slightly and rest your hands on a chair.",
                           bundle: .module, comment: "Wide-leg forward fold: an easier version, as a short instruction")
        )
    }

    static var crossBodyShoulderStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Cross-body shoulder stretch", keyStem: "crossBodyShoulderStretch",
            displayName: String(localized: "exercise.crossBodyShoulderStretch.name", defaultValue: "Cross-body shoulder stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.crossBodyShoulderStretch.cue1", defaultValue: "Bring one arm across your chest at shoulder height.",
                       bundle: .module, comment: "Cross-body shoulder stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.crossBodyShoulderStretch.cue2", defaultValue: "Hold it above the elbow with your other hand.",
                       bundle: .module, comment: "Cross-body shoulder stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.crossBodyShoulderStretch.cue3", defaultValue: "Keep your shoulder down, away from your ear.",
                       bundle: .module, comment: "Cross-body shoulder stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.crossBodyShoulderStretch.cue4", defaultValue: "Feel the stretch at the back of your shoulder.",
                       bundle: .module, comment: "Cross-body shoulder stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.crossBodyShoulderStretch.cue5", defaultValue: "Breathe slowly, then switch arms.",
                       bundle: .module, comment: "Cross-body shoulder stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.crossBodyShoulderStretch.mistake", defaultValue: "Pulling on the elbow joint itself, or shrugging up.",
                            bundle: .module, comment: "Cross-body shoulder stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.crossBodyShoulderStretch.easier", defaultValue: "Let the arm rest across your chest without pulling.",
                           bundle: .module, comment: "Cross-body shoulder stretch: an easier version, as a short instruction")
        )
    }

    static var overheadTricepsStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Overhead triceps stretch", keyStem: "overheadTricepsStretch",
            displayName: String(localized: "exercise.overheadTricepsStretch.name", defaultValue: "Overhead triceps stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.overheadTricepsStretch.cue1", defaultValue: "Reach one arm up and bend the elbow behind your head.",
                       bundle: .module, comment: "Overhead triceps stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.overheadTricepsStretch.cue2", defaultValue: "Use your other hand to guide the elbow back gently.",
                       bundle: .module, comment: "Overhead triceps stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.overheadTricepsStretch.cue3", defaultValue: "Keep your head up and your ribs down.",
                       bundle: .module, comment: "Overhead triceps stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.overheadTricepsStretch.cue4", defaultValue: "Feel the stretch along the back of your upper arm.",
                       bundle: .module, comment: "Overhead triceps stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.overheadTricepsStretch.cue5", defaultValue: "Breathe steadily, then switch arms.",
                       bundle: .module, comment: "Overhead triceps stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.overheadTricepsStretch.mistake", defaultValue: "Pushing the head forward or arching the lower back.",
                            bundle: .module, comment: "Overhead triceps stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.overheadTricepsStretch.easier", defaultValue: "Rest the hand on top of your shoulder and skip the pull.",
                           bundle: .module, comment: "Overhead triceps stretch: an easier version, as a short instruction")
        )
    }

    static var figureFourStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Figure-four stretch", keyStem: "figureFourStretch",
            displayName: String(localized: "exercise.figureFourStretch.name", defaultValue: "Figure-four stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.figureFourStretch.cue1", defaultValue: "Lie on your back with your knees bent.",
                       bundle: .module, comment: "Figure-four stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.figureFourStretch.cue2", defaultValue: "Cross one ankle over the opposite knee.",
                       bundle: .module, comment: "Figure-four stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.figureFourStretch.cue3", defaultValue: "Pull the lower thigh gently toward your chest.",
                       bundle: .module, comment: "Figure-four stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.figureFourStretch.cue4", defaultValue: "Feel the stretch deep in the hip of the crossed leg.",
                       bundle: .module, comment: "Figure-four stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.figureFourStretch.cue5", defaultValue: "Breathe slowly, then switch sides.",
                       bundle: .module, comment: "Figure-four stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.figureFourStretch.mistake", defaultValue: "Lifting the head and shoulders off the floor to pull harder.",
                            bundle: .module, comment: "Figure-four stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.figureFourStretch.easier", defaultValue: "Do it seated in a chair, one ankle over the other knee.",
                           bundle: .module, comment: "Figure-four stretch: an easier version, as a short instruction")
        )
    }

    static var doorwayChestStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Doorway chest stretch", keyStem: "doorwayChestStretch",
            displayName: String(localized: "exercise.doorwayChestStretch.name", defaultValue: "Doorway chest stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.doorwayChestStretch.cue1", defaultValue: "Stand in a doorway, forearms on the frame at shoulder height.",
                       bundle: .module, comment: "Doorway chest stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.doorwayChestStretch.cue2", defaultValue: "Step one foot forward slowly.",
                       bundle: .module, comment: "Doorway chest stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.doorwayChestStretch.cue3", defaultValue: "Keep your shoulders down and back.",
                       bundle: .module, comment: "Doorway chest stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.doorwayChestStretch.cue4", defaultValue: "Feel the stretch across the front of your chest.",
                       bundle: .module, comment: "Doorway chest stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.doorwayChestStretch.cue5", defaultValue: "Breathe slowly and ease forward a little as you breathe out.",
                       bundle: .module, comment: "Doorway chest stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.doorwayChestStretch.mistake", defaultValue: "Leaning in too far and letting the lower back arch.",
                            bundle: .module, comment: "Doorway chest stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.doorwayChestStretch.easier", defaultValue: "Use one arm at a time, or place your hands lower on the frame.",
                           bundle: .module, comment: "Doorway chest stretch: an easier version, as a short instruction")
        )
    }

    static var calfStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Calf stretch", keyStem: "calfStretch",
            displayName: String(localized: "exercise.calfStretch.name", defaultValue: "Calf stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.calfStretch.cue1", defaultValue: "Face a wall with your hands on it.",
                       bundle: .module, comment: "Calf stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.calfStretch.cue2", defaultValue: "Step one foot back and press the heel down.",
                       bundle: .module, comment: "Calf stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.calfStretch.cue3", defaultValue: "Keep the back leg straight and your toes pointing forward.",
                       bundle: .module, comment: "Calf stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.calfStretch.cue4", defaultValue: "Feel the stretch in the calf of the back leg.",
                       bundle: .module, comment: "Calf stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.calfStretch.cue5", defaultValue: "Breathe steadily, then switch legs.",
                       bundle: .module, comment: "Calf stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.calfStretch.mistake", defaultValue: "Letting the back heel lift off the floor.",
                            bundle: .module, comment: "Calf stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.calfStretch.easier", defaultValue: "Take a shorter step back.",
                           bundle: .module, comment: "Calf stretch: an easier version, as a short instruction")
        )
    }

    static var threadTheNeedle: ExerciseHowTo {
        ExerciseHowTo(
            name: "Thread the needle", keyStem: "threadTheNeedle",
            displayName: String(localized: "exercise.threadTheNeedle.name", defaultValue: "Thread the needle",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.threadTheNeedle.cue1", defaultValue: "Start on hands and knees.",
                       bundle: .module, comment: "Thread the needle: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.threadTheNeedle.cue2", defaultValue: "Slide one arm under your body along the floor.",
                       bundle: .module, comment: "Thread the needle: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.threadTheNeedle.cue3", defaultValue: "Rest that shoulder and the side of your head down.",
                       bundle: .module, comment: "Thread the needle: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.threadTheNeedle.cue4", defaultValue: "Feel the stretch between your shoulder blades.",
                       bundle: .module, comment: "Thread the needle: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.threadTheNeedle.cue5", defaultValue: "Breathe slowly, then switch sides.",
                       bundle: .module, comment: "Thread the needle: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.threadTheNeedle.mistake", defaultValue: "Shifting the hips to the side instead of turning the upper back.",
                            bundle: .module, comment: "Thread the needle: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.threadTheNeedle.easier", defaultValue: "Slide the arm only partway, keeping your head off the floor.",
                           bundle: .module, comment: "Thread the needle: an easier version, as a short instruction")
        )
    }

    static var supineTwist: ExerciseHowTo {
        ExerciseHowTo(
            name: "Supine twist", keyStem: "supineTwist",
            displayName: String(localized: "exercise.supineTwist.name", defaultValue: "Supine twist",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.supineTwist.cue1", defaultValue: "Lie on your back with your knees bent.",
                       bundle: .module, comment: "Supine twist: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.supineTwist.cue2", defaultValue: "Stretch your arms out to the sides.",
                       bundle: .module, comment: "Supine twist: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.supineTwist.cue3", defaultValue: "Let both knees fall slowly to one side.",
                       bundle: .module, comment: "Supine twist: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.supineTwist.cue4", defaultValue: "Feel the twist through your lower back and side.",
                       bundle: .module, comment: "Supine twist: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.supineTwist.cue5", defaultValue: "Breathe slowly, then bring your knees back and switch.",
                       bundle: .module, comment: "Supine twist: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.supineTwist.mistake", defaultValue: "Forcing the knees down or lifting the opposite shoulder high.",
                            bundle: .module, comment: "Supine twist: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.supineTwist.easier", defaultValue: "Let your knees fall only partway, resting them on a pillow.",
                           bundle: .module, comment: "Supine twist: an easier version, as a short instruction")
        )
    }

    static var neckSideStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Neck side stretch", keyStem: "neckSideStretch",
            displayName: String(localized: "exercise.neckSideStretch.name", defaultValue: "Neck side stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.neckSideStretch.cue1", defaultValue: "Sit or stand tall with your shoulders relaxed and low.",
                       bundle: .module, comment: "Neck side stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.neckSideStretch.cue2", defaultValue: "Slowly tip one ear toward that shoulder.",
                       bundle: .module, comment: "Neck side stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.neckSideStretch.cue3", defaultValue: "Ease in gently, with no bouncing and never into pain.",
                       bundle: .module, comment: "Neck side stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.neckSideStretch.cue4", defaultValue: "Feel a light stretch along the side of your neck.",
                       bundle: .module, comment: "Neck side stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.neckSideStretch.cue5", defaultValue: "Breathe slowly, lift your head back to center, then switch sides.",
                       bundle: .module, comment: "Neck side stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.neckSideStretch.mistake", defaultValue: "Pulling your head down with your hand to go deeper.",
                            bundle: .module, comment: "Neck side stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.neckSideStretch.easier", defaultValue: "Tip your head only a little, keeping the stretch very light.",
                           bundle: .module, comment: "Neck side stretch: an easier version, as a short instruction")
        )
    }

    static var cobraStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Cobra stretch", keyStem: "cobraStretch",
            displayName: String(localized: "exercise.cobraStretch.name", defaultValue: "Cobra stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.cobraStretch.cue1", defaultValue: "Lie face down with your hands under your shoulders.",
                       bundle: .module, comment: "Cobra stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.cobraStretch.cue2", defaultValue: "Press gently to lift your chest, hips staying on the floor.",
                       bundle: .module, comment: "Cobra stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.cobraStretch.cue3", defaultValue: "Rise slowly with no bouncing, and never into pain.",
                       bundle: .module, comment: "Cobra stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.cobraStretch.cue4", defaultValue: "Feel a gentle stretch across your belly and chest.",
                       bundle: .module, comment: "Cobra stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.cobraStretch.cue5", defaultValue: "Breathe slowly, then lower yourself down with control.",
                       bundle: .module, comment: "Cobra stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.cobraStretch.mistake", defaultValue: "Pushing up too high, so the lower back pinches.",
                            bundle: .module, comment: "Cobra stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.cobraStretch.easier", defaultValue: "Rest on your forearms, elbows under your shoulders.",
                           bundle: .module, comment: "Cobra stretch: an easier version, as a short instruction")
        )
    }

    static var kneeToChestStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Knee-to-chest stretch", keyStem: "kneeToChestStretch",
            displayName: String(localized: "exercise.kneeToChestStretch.name", defaultValue: "Knee-to-chest stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.kneeToChestStretch.cue1", defaultValue: "Lie on your back with your knees bent and feet flat.",
                       bundle: .module, comment: "Knee-to-chest stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.kneeToChestStretch.cue2", defaultValue: "Hold behind your knees and draw them gently toward your chest.",
                       bundle: .module, comment: "Knee-to-chest stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.kneeToChestStretch.cue3", defaultValue: "Ease in slowly, with no bouncing and never into pain.",
                       bundle: .module, comment: "Knee-to-chest stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.kneeToChestStretch.cue4", defaultValue: "Feel a gentle stretch through your lower back and hips.",
                       bundle: .module, comment: "Knee-to-chest stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.kneeToChestStretch.cue5", defaultValue: "Breathe slowly and let your back relax into the floor.",
                       bundle: .module, comment: "Knee-to-chest stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.kneeToChestStretch.mistake", defaultValue: "Lifting your head and shoulders to pull the knees in harder.",
                            bundle: .module, comment: "Knee-to-chest stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.kneeToChestStretch.easier", defaultValue: "Bring one knee in at a time, keeping the other foot down.",
                           bundle: .module, comment: "Knee-to-chest stretch: an easier version, as a short instruction")
        )
    }

    static var pigeonStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Pigeon stretch", keyStem: "pigeonStretch",
            displayName: String(localized: "exercise.pigeonStretch.name", defaultValue: "Pigeon stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.pigeonStretch.cue1", defaultValue: "From hands and knees, bring one knee forward behind that wrist.",
                       bundle: .module, comment: "Pigeon stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.pigeonStretch.cue2", defaultValue: "Slide the other leg straight back behind you.",
                       bundle: .module, comment: "Pigeon stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.pigeonStretch.cue3", defaultValue: "Lower your hips slowly with no bouncing, never into pain.",
                       bundle: .module, comment: "Pigeon stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.pigeonStretch.cue4", defaultValue: "Feel the stretch deep in the hip of the bent leg.",
                       bundle: .module, comment: "Pigeon stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.pigeonStretch.cue5", defaultValue: "Breathe slowly, then switch sides.",
                       bundle: .module, comment: "Pigeon stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.pigeonStretch.mistake", defaultValue: "Forcing the front shin flat across, which can strain the knee.",
                            bundle: .module, comment: "Pigeon stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.pigeonStretch.easier", defaultValue: "Rest your hip on a cushion, or do the figure-four stretch instead.",
                           bundle: .module, comment: "Pigeon stretch: an easier version, as a short instruction")
        )
    }

    static var seatedHamstringStretch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Seated hamstring stretch", keyStem: "seatedHamstringStretch",
            displayName: String(localized: "exercise.seatedHamstringStretch.name", defaultValue: "Seated hamstring stretch",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.seatedHamstringStretch.cue1", defaultValue: "Sit tall with one leg straight and the other knee bent.",
                       bundle: .module, comment: "Seated hamstring stretch: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.seatedHamstringStretch.cue2", defaultValue: "Hinge forward from your hips, reaching toward your foot.",
                       bundle: .module, comment: "Seated hamstring stretch: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.seatedHamstringStretch.cue3", defaultValue: "Ease in slowly, with no bouncing and never into pain.",
                       bundle: .module, comment: "Seated hamstring stretch: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.seatedHamstringStretch.cue4", defaultValue: "Feel the stretch along the back of the straight leg.",
                       bundle: .module, comment: "Seated hamstring stretch: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.seatedHamstringStretch.cue5", defaultValue: "Breathe slowly, then switch legs.",
                       bundle: .module, comment: "Seated hamstring stretch: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.seatedHamstringStretch.mistake", defaultValue: "Rounding your back to reach your toes.",
                            bundle: .module, comment: "Seated hamstring stretch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.seatedHamstringStretch.easier", defaultValue: "Sit on a folded towel and loop a strap around your foot.",
                           bundle: .module, comment: "Seated hamstring stretch: an easier version, as a short instruction")
        )
    }

    static var wristCircles: ExerciseHowTo {
        ExerciseHowTo(
            name: "Wrist circles", keyStem: "wristCircles",
            displayName: String(localized: "exercise.wristCircles.name", defaultValue: "Wrist circles",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.wristCircles.cue1", defaultValue: "Hold your arms in front with your hands loose.",
                       bundle: .module, comment: "Wrist circles: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.wristCircles.cue2", defaultValue: "Make small, slow circles with your wrists, growing them gradually.",
                       bundle: .module, comment: "Wrist circles: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.wristCircles.cue3", defaultValue: "Switch direction halfway through.",
                       bundle: .module, comment: "Wrist circles: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.wristCircles.cue4", defaultValue: "Feel your wrists and forearms loosen and warm up.",
                       bundle: .module, comment: "Wrist circles: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.wristCircles.cue5", defaultValue: "Breathe easily and keep each circle smooth, never into pain.",
                       bundle: .module, comment: "Wrist circles: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.wristCircles.mistake", defaultValue: "Rushing the circles or forcing the wrists to their limit.",
                            bundle: .module, comment: "Wrist circles: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.wristCircles.easier", defaultValue: "Make smaller circles with your elbows resting on a table.",
                           bundle: .module, comment: "Wrist circles: an easier version, as a short instruction")
        )
    }

    static var upperBackFoamRoll: ExerciseHowTo {
        ExerciseHowTo(
            name: "Upper back foam roll", keyStem: "upperBackFoamRoll",
            displayName: String(localized: "exercise.upperBackFoamRoll.name", defaultValue: "Upper back foam roll",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.upperBackFoamRoll.cue1", defaultValue: "Lie back with the foam roller under your upper back.",
                       bundle: .module, comment: "Upper back foam roll: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.upperBackFoamRoll.cue2", defaultValue: "Rest your head in your hands, knees bent and feet flat.",
                       bundle: .module, comment: "Upper back foam roll: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.upperBackFoamRoll.cue3", defaultValue: "Roll slowly along your upper back, never your lower back or neck.",
                       bundle: .module, comment: "Upper back foam roll: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.upperBackFoamRoll.cue4", defaultValue: "Pause on a tight spot and feel it ease, never into pain.",
                       bundle: .module, comment: "Upper back foam roll: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.upperBackFoamRoll.cue5", defaultValue: "Breathe slowly and let your upper back relax over the roller.",
                       bundle: .module, comment: "Upper back foam roll: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.upperBackFoamRoll.mistake", defaultValue: "Rolling the lower back or neck instead of the upper back.",
                            bundle: .module, comment: "Upper back foam roll: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.upperBackFoamRoll.easier", defaultValue: "Stand with the roller between your upper back and a wall.",
                           bundle: .module, comment: "Upper back foam roll: an easier version, as a short instruction")
        )
    }

    static var legSwings: ExerciseHowTo {
        ExerciseHowTo(
            name: "Leg swings", keyStem: "legSwings",
            displayName: String(localized: "exercise.legSwings.name", defaultValue: "Leg swings",
                                bundle: .module, comment: "Exercise name shown on screen (a stretch)"),
            cues: [
                String(localized: "exercise.legSwings.cue1", defaultValue: "Stand sideways next to a wall, holding it for balance.",
                       bundle: .module, comment: "Leg swings: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.legSwings.cue2", defaultValue: "Swing your outside leg forward and back, smooth and controlled.",
                       bundle: .module, comment: "Leg swings: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.legSwings.cue3", defaultValue: "Start small and let the swings grow, never into pain.",
                       bundle: .module, comment: "Leg swings: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.legSwings.cue4", defaultValue: "Feel your hamstrings and hips loosen as you swing.",
                       bundle: .module, comment: "Leg swings: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.legSwings.cue5", defaultValue: "Breathe steadily, keep your torso tall, then switch legs.",
                       bundle: .module, comment: "Leg swings: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.legSwings.mistake", defaultValue: "Rocking the upper body to kick the leg higher.",
                            bundle: .module, comment: "Leg swings: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.legSwings.easier", defaultValue: "Make smaller, slower swings while holding a sturdy chair.",
                           bundle: .module, comment: "Leg swings: an easier version, as a short instruction")
        )
    }
}
