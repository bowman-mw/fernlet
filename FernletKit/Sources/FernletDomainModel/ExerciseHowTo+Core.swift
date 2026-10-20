// ExerciseHowTo+Core.swift
// FernletDomainModel — how-to text for the catalog's core and carries: planks, holds, anti-rotation, carries and balance.
//
// Fernlet-written, clean-room text (no website, dataset or book was copied or paraphrased),
// awaiting one review by a qualified coach before it ships. Every string is a catalog key under
// `exercise.<keyStem>.` resolved against `.module`; the English default here is what
// Scripts/sync-string-catalogs.sh harvests into Localizable.xcstrings, so edit both together.

import Foundation

extension ExerciseHowToCatalog {
    /// Core and carries: planks, holds, anti-rotation, carries and balance. In catalog order.
    static var coreEntries: [ExerciseHowTo] {
        [
            plank,
            sidePlank,
            hangingLegRaise,
            abWheel,
            cableCrunch,
            russianTwist,
            pallofPress,
            hollowHold,
            birdDog,
            superman,
            farmersCarry,
            suitcaseCarry,
            deadBug,
            singleLegStance,
        ]
    }

    static var plank: ExerciseHowTo {
        ExerciseHowTo(
            name: "Plank", keyStem: "plank",
            displayName: String(localized: "exercise.plank.name", defaultValue: "Plank",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.plank.cue1", defaultValue: "Rest on your forearms, elbows under your shoulders.",
                       bundle: .module, comment: "Plank: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.plank.cue2", defaultValue: "Make a straight line from head to heels.",
                       bundle: .module, comment: "Plank: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.plank.cue3", defaultValue: "Squeeze your glutes and pull your belly button in.",
                       bundle: .module, comment: "Plank: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.plank.cue4", defaultValue: "Feel it in your stomach, not your lower back.",
                       bundle: .module, comment: "Plank: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.plank.cue5", defaultValue: "Breathe slowly and steadily; don't hold your breath.",
                       bundle: .module, comment: "Plank: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.plank.mistake", defaultValue: "Letting the hips sag toward the floor or lifting them high.",
                            bundle: .module, comment: "Plank: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.plank.easier", defaultValue: "Rest your knees on the floor, or hold the plank for less time.",
                           bundle: .module, comment: "Plank: an easier version, as a short instruction")
        )
    }

    static var sidePlank: ExerciseHowTo {
        ExerciseHowTo(
            name: "Side plank", keyStem: "sidePlank",
            displayName: String(localized: "exercise.sidePlank.name", defaultValue: "Side plank",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.sidePlank.cue1", defaultValue: "Lie on your side with your elbow under your shoulder.",
                       bundle: .module, comment: "Side plank: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.sidePlank.cue2", defaultValue: "Stack your feet and lift your hips off the floor.",
                       bundle: .module, comment: "Side plank: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.sidePlank.cue3", defaultValue: "Keep your body straight from head to feet.",
                       bundle: .module, comment: "Side plank: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.sidePlank.cue4", defaultValue: "Feel it along the side of your waist.",
                       bundle: .module, comment: "Side plank: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.sidePlank.cue5", defaultValue: "Breathe steadily the whole time, then switch sides.",
                       bundle: .module, comment: "Side plank: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.sidePlank.mistake", defaultValue: "Letting the hips drop or roll forward or back.",
                            bundle: .module, comment: "Side plank: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.sidePlank.easier", defaultValue: "Bend your knees and rest them on the floor.",
                           bundle: .module, comment: "Side plank: an easier version, as a short instruction")
        )
    }

    static var hangingLegRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hanging leg raise", keyStem: "hangingLegRaise",
            displayName: String(localized: "exercise.hangingLegRaise.name", defaultValue: "Hanging leg raise",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.hangingLegRaise.cue1", defaultValue: "Hang from a bar with straight arms, shoulders pulled down.",
                       bundle: .module, comment: "Hanging leg raise: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.hangingLegRaise.cue2", defaultValue: "Brace your stomach to keep your body from swinging.",
                       bundle: .module, comment: "Hanging leg raise: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.hangingLegRaise.cue3", defaultValue: "Lift your legs by curling your hips up.",
                       bundle: .module, comment: "Hanging leg raise: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.hangingLegRaise.cue4", defaultValue: "Lower slowly without swinging into the next rep.",
                       bundle: .module, comment: "Hanging leg raise: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hangingLegRaise.mistake", defaultValue: "Swinging the legs up with momentum instead of curling with the stomach.",
                            bundle: .module, comment: "Hanging leg raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hangingLegRaise.easier", defaultValue: "Raise bent knees instead, or do lying leg raises on the floor.",
                           bundle: .module, comment: "Hanging leg raise: an easier version, as a short instruction")
        )
    }

    static var abWheel: ExerciseHowTo {
        ExerciseHowTo(
            name: "Ab wheel", keyStem: "abWheel",
            displayName: String(localized: "exercise.abWheel.name", defaultValue: "Ab wheel",
                                bundle: .module, comment: "Exercise name shown on screen (exercise)"),
            cues: [
                String(localized: "exercise.abWheel.cue1", defaultValue: "Kneel on a soft mat, hands on the wheel under your shoulders.",
                       bundle: .module, comment: "Ab wheel: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.abWheel.cue2", defaultValue: "Brace your stomach and tuck your hips slightly.",
                       bundle: .module, comment: "Ab wheel: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.abWheel.cue3", defaultValue: "Roll forward slowly, only as far as your back stays flat.",
                       bundle: .module, comment: "Ab wheel: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.abWheel.cue4", defaultValue: "Pull back with your stomach, not your hips.",
                       bundle: .module, comment: "Ab wheel: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.abWheel.mistake", defaultValue: "Rolling out too far so the lower back sags and arches.",
                            bundle: .module, comment: "Ab wheel: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.abWheel.easier", defaultValue: "Roll out a short distance, or roll toward a wall that stops you.",
                           bundle: .module, comment: "Ab wheel: an easier version, as a short instruction")
        )
    }

    static var cableCrunch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Cable crunch", keyStem: "cableCrunch",
            displayName: String(localized: "exercise.cableCrunch.name", defaultValue: "Cable crunch",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.cableCrunch.cue1", defaultValue: "Kneel facing the machine, rope held beside your head.",
                       bundle: .module, comment: "Cable crunch: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.cableCrunch.cue2", defaultValue: "Keep your hips still and above your knees.",
                       bundle: .module, comment: "Cable crunch: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.cableCrunch.cue3", defaultValue: "Curl your ribs toward your hips, rounding your back.",
                       bundle: .module, comment: "Cable crunch: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.cableCrunch.cue4", defaultValue: "Return slowly until your back is long again.",
                       bundle: .module, comment: "Cable crunch: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.cableCrunch.mistake", defaultValue: "Sitting the hips back and pulling with the arms instead of the stomach.",
                            bundle: .module, comment: "Cable crunch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.cableCrunch.easier", defaultValue: "Use a lighter weight, or do crunches on the floor.",
                           bundle: .module, comment: "Cable crunch: an easier version, as a short instruction")
        )
    }

    static var russianTwist: ExerciseHowTo {
        ExerciseHowTo(
            name: "Russian twist", keyStem: "russianTwist",
            displayName: String(localized: "exercise.russianTwist.name", defaultValue: "Russian twist",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.russianTwist.cue1", defaultValue: "Sit with knees bent and lean back a little, back straight.",
                       bundle: .module, comment: "Russian twist: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.russianTwist.cue2", defaultValue: "Hold your hands together in front of your chest.",
                       bundle: .module, comment: "Russian twist: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.russianTwist.cue3", defaultValue: "Turn your shoulders to one side, then the other.",
                       bundle: .module, comment: "Russian twist: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.russianTwist.cue4", defaultValue: "Move slowly and keep your chest tall.",
                       bundle: .module, comment: "Russian twist: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.russianTwist.mistake", defaultValue: "Swinging only the arms while the shoulders and chest stay still.",
                            bundle: .module, comment: "Russian twist: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.russianTwist.easier", defaultValue: "Keep your heels on the floor and sit more upright.",
                           bundle: .module, comment: "Russian twist: an easier version, as a short instruction")
        )
    }

    static var pallofPress: ExerciseHowTo {
        ExerciseHowTo(
            name: "Pallof press", keyStem: "pallofPress",
            displayName: String(localized: "exercise.pallofPress.name", defaultValue: "Pallof press",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.pallofPress.cue1", defaultValue: "Stand side-on to the cable with the handle at chest height.",
                       bundle: .module, comment: "Pallof press: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.pallofPress.cue2", defaultValue: "Hold the handle against your chest with both hands.",
                       bundle: .module, comment: "Pallof press: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.pallofPress.cue3", defaultValue: "Press your hands straight out without letting your body turn.",
                       bundle: .module, comment: "Pallof press: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.pallofPress.cue4", defaultValue: "Hold briefly, then bring your hands back in.",
                       bundle: .module, comment: "Pallof press: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.pallofPress.cue5", defaultValue: "Repeat facing the other way.",
                       bundle: .module, comment: "Pallof press: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.pallofPress.mistake", defaultValue: "Letting the cable pull the shoulders and hips around.",
                            bundle: .module, comment: "Pallof press: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.pallofPress.easier", defaultValue: "Use a lighter weight, or stand closer to the machine.",
                           bundle: .module, comment: "Pallof press: an easier version, as a short instruction")
        )
    }

    static var hollowHold: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hollow hold", keyStem: "hollowHold",
            displayName: String(localized: "exercise.hollowHold.name", defaultValue: "Hollow hold",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.hollowHold.cue1", defaultValue: "Lie on your back and press your lower back into the floor.",
                       bundle: .module, comment: "Hollow hold: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.hollowHold.cue2", defaultValue: "Lift your shoulders and legs just off the floor.",
                       bundle: .module, comment: "Hollow hold: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.hollowHold.cue3", defaultValue: "Reach your arms forward or overhead, lower back still down.",
                       bundle: .module, comment: "Hollow hold: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.hollowHold.cue4", defaultValue: "Feel it in your stomach; stop if your back lifts.",
                       bundle: .module, comment: "Hollow hold: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.hollowHold.cue5", defaultValue: "Breathe in short, steady breaths without letting go of the brace.",
                       bundle: .module, comment: "Hollow hold: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hollowHold.mistake", defaultValue: "Letting the lower back peel off the floor as you tire.",
                            bundle: .module, comment: "Hollow hold: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hollowHold.easier", defaultValue: "Bend your knees and keep your arms by your sides.",
                           bundle: .module, comment: "Hollow hold: an easier version, as a short instruction")
        )
    }

    static var birdDog: ExerciseHowTo {
        ExerciseHowTo(
            name: "Bird dog", keyStem: "birdDog",
            displayName: String(localized: "exercise.birdDog.name", defaultValue: "Bird dog",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.birdDog.cue1", defaultValue: "Start on hands and knees, hands under your shoulders.",
                       bundle: .module, comment: "Bird dog: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.birdDog.cue2", defaultValue: "Reach one arm forward and the opposite leg back.",
                       bundle: .module, comment: "Bird dog: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.birdDog.cue3", defaultValue: "Keep your back flat and your hips level.",
                       bundle: .module, comment: "Bird dog: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.birdDog.cue4", defaultValue: "Pause, return slowly, then switch sides.",
                       bundle: .module, comment: "Bird dog: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.birdDog.mistake", defaultValue: "Lifting the leg too high so the lower back arches.",
                            bundle: .module, comment: "Bird dog: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.birdDog.easier", defaultValue: "Move only an arm or only a leg, one at a time.",
                           bundle: .module, comment: "Bird dog: an easier version, as a short instruction")
        )
    }

    static var superman: ExerciseHowTo {
        ExerciseHowTo(
            name: "Superman", keyStem: "superman",
            displayName: String(localized: "exercise.superman.name", defaultValue: "Superman",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.superman.cue1", defaultValue: "Lie face down with your arms reaching forward.",
                       bundle: .module, comment: "Superman: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.superman.cue2", defaultValue: "Lift your arms, chest and legs a little off the floor.",
                       bundle: .module, comment: "Superman: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.superman.cue3", defaultValue: "Keep your neck long and look at the floor.",
                       bundle: .module, comment: "Superman: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.superman.cue4", defaultValue: "Hold briefly, then lower slowly.",
                       bundle: .module, comment: "Superman: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.superman.mistake", defaultValue: "Lifting as high as possible and tipping the head back.",
                            bundle: .module, comment: "Superman: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.superman.easier", defaultValue: "Lift only your arms, or only your legs, each time.",
                           bundle: .module, comment: "Superman: an easier version, as a short instruction")
        )
    }

    static var farmersCarry: ExerciseHowTo {
        ExerciseHowTo(
            name: "Farmer's carry", keyStem: "farmersCarry",
            displayName: String(localized: "exercise.farmersCarry.name", defaultValue: "Farmer's carry",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.farmersCarry.cue1", defaultValue: "Pick up the dumbbells with a flat back, like a deadlift.",
                       bundle: .module, comment: "Farmer's carry: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.farmersCarry.cue2", defaultValue: "Stand tall with your shoulders down and back.",
                       bundle: .module, comment: "Farmer's carry: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.farmersCarry.cue3", defaultValue: "Walk with short, steady steps.",
                       bundle: .module, comment: "Farmer's carry: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.farmersCarry.cue4", defaultValue: "Feel it in your grip, shoulders and core.",
                       bundle: .module, comment: "Farmer's carry: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.farmersCarry.cue5", defaultValue: "Breathe steadily; don't hold your breath as you walk.",
                       bundle: .module, comment: "Farmer's carry: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.farmersCarry.mistake", defaultValue: "Leaning or shuffling with the shoulders rounded forward.",
                            bundle: .module, comment: "Farmer's carry: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.farmersCarry.easier", defaultValue: "Use lighter weights and walk for less time.",
                           bundle: .module, comment: "Farmer's carry: an easier version, as a short instruction")
        )
    }

    static var suitcaseCarry: ExerciseHowTo {
        ExerciseHowTo(
            name: "Suitcase carry", keyStem: "suitcaseCarry",
            displayName: String(localized: "exercise.suitcaseCarry.name", defaultValue: "Suitcase carry",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.suitcaseCarry.cue1", defaultValue: "Hold one dumbbell at your side, like a suitcase.",
                       bundle: .module, comment: "Suitcase carry: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.suitcaseCarry.cue2", defaultValue: "Stand tall without leaning toward the weight.",
                       bundle: .module, comment: "Suitcase carry: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.suitcaseCarry.cue3", defaultValue: "Walk slowly with short, steady steps.",
                       bundle: .module, comment: "Suitcase carry: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.suitcaseCarry.cue4", defaultValue: "Feel it along the side of your waist opposite the weight.",
                       bundle: .module, comment: "Suitcase carry: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.suitcaseCarry.cue5", defaultValue: "Breathe steadily, then switch hands.",
                       bundle: .module, comment: "Suitcase carry: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.suitcaseCarry.mistake", defaultValue: "Leaning toward the weight, or away from it to balance.",
                            bundle: .module, comment: "Suitcase carry: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.suitcaseCarry.easier", defaultValue: "Use a lighter weight and walk for less time.",
                           bundle: .module, comment: "Suitcase carry: an easier version, as a short instruction")
        )
    }

    static var deadBug: ExerciseHowTo {
        ExerciseHowTo(
            name: "Dead bug", keyStem: "deadBug",
            displayName: String(localized: "exercise.deadBug.name", defaultValue: "Dead bug",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.deadBug.cue1", defaultValue: "Lie on your back, arms up, knees bent above your hips.",
                       bundle: .module, comment: "Dead bug: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.deadBug.cue2", defaultValue: "Press your lower back gently into the floor.",
                       bundle: .module, comment: "Dead bug: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.deadBug.cue3", defaultValue: "Lower one arm and the opposite leg slowly.",
                       bundle: .module, comment: "Dead bug: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.deadBug.cue4", defaultValue: "Return, then switch sides.",
                       bundle: .module, comment: "Dead bug: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.deadBug.cue5", defaultValue: "Breathe out as you reach away.",
                       bundle: .module, comment: "Dead bug: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.deadBug.mistake", defaultValue: "Letting the lower back arch off the floor as the leg lowers.",
                            bundle: .module, comment: "Dead bug: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.deadBug.easier", defaultValue: "Move only the legs, tapping a heel down with the knee bent.",
                           bundle: .module, comment: "Dead bug: an easier version, as a short instruction")
        )
    }

    static var singleLegStance: ExerciseHowTo {
        ExerciseHowTo(
            name: "Single-leg stance", keyStem: "singleLegStance",
            displayName: String(localized: "exercise.singleLegStance.name", defaultValue: "Single-leg stance",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.singleLegStance.cue1", defaultValue: "Stand near a wall or chair for support.",
                       bundle: .module, comment: "Single-leg stance: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.singleLegStance.cue2", defaultValue: "Lift one foot just off the floor.",
                       bundle: .module, comment: "Single-leg stance: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.singleLegStance.cue3", defaultValue: "Keep your hips level and your standing knee soft.",
                       bundle: .module, comment: "Single-leg stance: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.singleLegStance.cue4", defaultValue: "Feel it in the side of your standing hip.",
                       bundle: .module, comment: "Single-leg stance: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.singleLegStance.cue5", defaultValue: "Breathe steadily, then switch legs.",
                       bundle: .module, comment: "Single-leg stance: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.singleLegStance.mistake", defaultValue: "Locking the standing knee and holding your breath.",
                            bundle: .module, comment: "Single-leg stance: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.singleLegStance.easier", defaultValue: "Rest a hand on the wall, or touch the lifted toes down.",
                           bundle: .module, comment: "Single-leg stance: an easier version, as a short instruction")
        )
    }
}
