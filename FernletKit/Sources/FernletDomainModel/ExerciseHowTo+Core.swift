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
            crunch,
            curlUp,
            lyingLegRaise,
            hangingKneeRaise,
            kneePlank,
            bentKneeSidePlank,
            vUp,
            weightedVUp,
            alternatingKneeTuck,
            tuckedToeTap,
            reverseCrunch,
            bicycleCrunch,
            flutterKick,
            heelTap,
            hollowRock,
            plankShoulderTap,
            cableWoodchopper,
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

    static var crunch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Crunch", keyStem: "crunch",
            displayName: String(localized: "exercise.crunch.name", defaultValue: "Crunch",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.crunch.cue1", defaultValue: "Lie on your back, knees bent, feet flat on the floor.",
                       bundle: .module, comment: "Crunch: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.crunch.cue2", defaultValue: "Rest your fingertips lightly behind your head, elbows wide.",
                       bundle: .module, comment: "Crunch: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.crunch.cue3", defaultValue: "Curl your shoulders off the floor using your stomach.",
                       bundle: .module, comment: "Crunch: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.crunch.cue4", defaultValue: "Pause briefly, then lower slowly.",
                       bundle: .module, comment: "Crunch: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.crunch.mistake", defaultValue: "Pulling on the head and neck to lift yourself up.",
                            bundle: .module, comment: "Crunch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.crunch.easier", defaultValue: "Cross your arms on your chest, and lift only a little.",
                           bundle: .module, comment: "Crunch: an easier version, as a short instruction")
        )
    }

    static var curlUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Curl-up", keyStem: "curlUp",
            displayName: String(localized: "exercise.curlUp.name", defaultValue: "Curl-up",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.curlUp.cue1", defaultValue: "Lie on your back, knees bent, arms straight by your sides.",
                       bundle: .module, comment: "Curl-up: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.curlUp.cue2", defaultValue: "Curl your head and shoulders up, sliding your hands forward.",
                       bundle: .module, comment: "Curl-up: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.curlUp.cue3", defaultValue: "Lift only until your shoulder blades clear the floor.",
                       bundle: .module, comment: "Curl-up: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.curlUp.cue4", defaultValue: "Lower slowly, keeping your neck relaxed.",
                       bundle: .module, comment: "Curl-up: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.curlUp.mistake", defaultValue: "Jerking up with the neck instead of curling with the stomach.",
                            bundle: .module, comment: "Curl-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.curlUp.easier", defaultValue: "Curl up a smaller distance, and rest between reps.",
                           bundle: .module, comment: "Curl-up: an easier version, as a short instruction")
        )
    }

    static var lyingLegRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Lying leg raise", keyStem: "lyingLegRaise",
            displayName: String(localized: "exercise.lyingLegRaise.name", defaultValue: "Lying leg raise",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.lyingLegRaise.cue1", defaultValue: "Lie on your back with your arms flat by your sides.",
                       bundle: .module, comment: "Lying leg raise: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.lyingLegRaise.cue2", defaultValue: "Press your lower back gently into the floor.",
                       bundle: .module, comment: "Lying leg raise: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.lyingLegRaise.cue3", defaultValue: "Lift your straight legs together until they point at the ceiling.",
                       bundle: .module, comment: "Lying leg raise: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.lyingLegRaise.cue4", defaultValue: "Lower them slowly, stopping before your lower back lifts.",
                       bundle: .module, comment: "Lying leg raise: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.lyingLegRaise.mistake", defaultValue: "Letting the lower back arch off the floor as the legs lower.",
                            bundle: .module, comment: "Lying leg raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.lyingLegRaise.easier", defaultValue: "Bend your knees, or lower one leg at a time.",
                           bundle: .module, comment: "Lying leg raise: an easier version, as a short instruction")
        )
    }

    static var hangingKneeRaise: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hanging knee raise", keyStem: "hangingKneeRaise",
            displayName: String(localized: "exercise.hangingKneeRaise.name", defaultValue: "Hanging knee raise",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.hangingKneeRaise.cue1", defaultValue: "Hang from a bar with straight arms, shoulders pulled down.",
                       bundle: .module, comment: "Hanging knee raise: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.hangingKneeRaise.cue2", defaultValue: "Brace your stomach so your body stays still.",
                       bundle: .module, comment: "Hanging knee raise: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.hangingKneeRaise.cue3", defaultValue: "Bring your knees up toward your chest, curling your hips.",
                       bundle: .module, comment: "Hanging knee raise: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.hangingKneeRaise.cue4", defaultValue: "Lower your legs slowly without swinging.",
                       bundle: .module, comment: "Hanging knee raise: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hangingKneeRaise.mistake", defaultValue: "Swinging the body to throw the knees up.",
                            bundle: .module, comment: "Hanging knee raise: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hangingKneeRaise.easier", defaultValue: "Do lying leg raises on the floor, with your knees bent.",
                           bundle: .module, comment: "Hanging knee raise: an easier version, as a short instruction")
        )
    }

    static var kneePlank: ExerciseHowTo {
        ExerciseHowTo(
            name: "Knee plank", keyStem: "kneePlank",
            displayName: String(localized: "exercise.kneePlank.name", defaultValue: "Knee plank",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.kneePlank.cue1", defaultValue: "Rest on your forearms and knees, elbows under your shoulders.",
                       bundle: .module, comment: "Knee plank: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.kneePlank.cue2", defaultValue: "Keep a straight line from your head to your knees.",
                       bundle: .module, comment: "Knee plank: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.kneePlank.cue3", defaultValue: "Pull your belly button in and squeeze your glutes gently.",
                       bundle: .module, comment: "Knee plank: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.kneePlank.cue4", defaultValue: "Feel it in your stomach, not your lower back.",
                       bundle: .module, comment: "Knee plank: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.kneePlank.cue5", defaultValue: "Breathe slowly and steadily the whole time.",
                       bundle: .module, comment: "Knee plank: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.kneePlank.mistake", defaultValue: "Pushing the hips up high or letting them sag.",
                            bundle: .module, comment: "Knee plank: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.kneePlank.easier", defaultValue: "Hold for less time, and rest between short holds.",
                           bundle: .module, comment: "Knee plank: an easier version, as a short instruction")
        )
    }

    static var bentKneeSidePlank: ExerciseHowTo {
        ExerciseHowTo(
            name: "Bent-knee side plank", keyStem: "bentKneeSidePlank",
            displayName: String(localized: "exercise.bentKneeSidePlank.name", defaultValue: "Bent-knee side plank",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.bentKneeSidePlank.cue1", defaultValue: "Lie on your side, elbow under your shoulder, knees bent.",
                       bundle: .module, comment: "Bent-knee side plank: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.bentKneeSidePlank.cue2", defaultValue: "Lift your hips until you're straight from head to knees.",
                       bundle: .module, comment: "Bent-knee side plank: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.bentKneeSidePlank.cue3", defaultValue: "Keep your hips stacked, not rolling forward or back.",
                       bundle: .module, comment: "Bent-knee side plank: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.bentKneeSidePlank.cue4", defaultValue: "Feel it along the side of your waist.",
                       bundle: .module, comment: "Bent-knee side plank: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.bentKneeSidePlank.cue5", defaultValue: "Breathe steadily the whole time, then switch sides.",
                       bundle: .module, comment: "Bent-knee side plank: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bentKneeSidePlank.mistake", defaultValue: "Letting the hips sink back toward the floor.",
                            bundle: .module, comment: "Bent-knee side plank: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bentKneeSidePlank.easier", defaultValue: "Hold for less time, or rest your top hand on the floor.",
                           bundle: .module, comment: "Bent-knee side plank: an easier version, as a short instruction")
        )
    }

    static var vUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "V-up", keyStem: "vUp",
            displayName: String(localized: "exercise.vUp.name", defaultValue: "V-up",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.vUp.cue1", defaultValue: "Lie on your back, legs straight, arms reaching overhead.",
                       bundle: .module, comment: "V-up: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.vUp.cue2", defaultValue: "Brace your stomach and press your lower back down.",
                       bundle: .module, comment: "V-up: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.vUp.cue3", defaultValue: "Lift your legs and upper body together, reaching for your shins.",
                       bundle: .module, comment: "V-up: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.vUp.cue4", defaultValue: "Lower slowly with control until you're lying flat again.",
                       bundle: .module, comment: "V-up: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.vUp.mistake", defaultValue: "Swinging up with momentum and dropping back down hard.",
                            bundle: .module, comment: "V-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.vUp.easier", defaultValue: "Bend your knees into a tuck as you come up.",
                           bundle: .module, comment: "V-up: an easier version, as a short instruction")
        )
    }

    static var weightedVUp: ExerciseHowTo {
        ExerciseHowTo(
            name: "Weighted V-up", keyStem: "weightedVUp",
            displayName: String(localized: "exercise.weightedVUp.name", defaultValue: "Weighted V-up",
                                bundle: .module, comment: "Exercise name shown on screen (dumbbell exercise)"),
            cues: [
                String(localized: "exercise.weightedVUp.cue1", defaultValue: "Lie on your back holding one dumbbell overhead in both hands.",
                       bundle: .module, comment: "Weighted V-up: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.weightedVUp.cue2", defaultValue: "Keep your legs straight and your lower back pressed down.",
                       bundle: .module, comment: "Weighted V-up: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.weightedVUp.cue3", defaultValue: "Lift your legs and chest together, bringing the weight toward your shins.",
                       bundle: .module, comment: "Weighted V-up: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.weightedVUp.cue4", defaultValue: "Lower slowly, keeping a firm grip on the dumbbell.",
                       bundle: .module, comment: "Weighted V-up: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.weightedVUp.mistake", defaultValue: "Swinging the dumbbell to throw the body up.",
                            bundle: .module, comment: "Weighted V-up: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.weightedVUp.easier", defaultValue: "Use a lighter dumbbell, or do V-ups with no weight.",
                           bundle: .module, comment: "Weighted V-up: an easier version, as a short instruction")
        )
    }

    static var alternatingKneeTuck: ExerciseHowTo {
        ExerciseHowTo(
            name: "Alternating knee tuck", keyStem: "alternatingKneeTuck",
            displayName: String(localized: "exercise.alternatingKneeTuck.name", defaultValue: "Alternating knee tuck",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.alternatingKneeTuck.cue1", defaultValue: "Sit on the floor and lean back on your hands or forearms.",
                       bundle: .module, comment: "Alternating knee tuck: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.alternatingKneeTuck.cue2", defaultValue: "Stretch both legs out long, just off the floor.",
                       bundle: .module, comment: "Alternating knee tuck: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.alternatingKneeTuck.cue3", defaultValue: "Draw one knee toward your chest as the other stays long.",
                       bundle: .module, comment: "Alternating knee tuck: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.alternatingKneeTuck.cue4", defaultValue: "Switch legs smoothly, keeping your chest lifted.",
                       bundle: .module, comment: "Alternating knee tuck: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.alternatingKneeTuck.mistake", defaultValue: "Slumping onto the hands so the back rounds.",
                            bundle: .module, comment: "Alternating knee tuck: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.alternatingKneeTuck.easier", defaultValue: "Rest the straight leg's heel on the floor between tucks.",
                           bundle: .module, comment: "Alternating knee tuck: an easier version, as a short instruction")
        )
    }

    static var tuckedToeTap: ExerciseHowTo {
        ExerciseHowTo(
            name: "Tucked toe tap", keyStem: "tuckedToeTap",
            displayName: String(localized: "exercise.tuckedToeTap.name", defaultValue: "Tucked toe tap",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.tuckedToeTap.cue1", defaultValue: "Lie on your back and press your lower back down.",
                       bundle: .module, comment: "Tucked toe tap: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.tuckedToeTap.cue2", defaultValue: "Lift your knees over your hips, shins level with the floor.",
                       bundle: .module, comment: "Tucked toe tap: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.tuckedToeTap.cue3", defaultValue: "Lower one foot, knee still bent, and tap your toes down.",
                       bundle: .module, comment: "Tucked toe tap: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.tuckedToeTap.cue4", defaultValue: "Bring it back up, then tap with the other foot.",
                       bundle: .module, comment: "Tucked toe tap: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.tuckedToeTap.mistake", defaultValue: "Letting the lower back arch as the foot lowers.",
                            bundle: .module, comment: "Tucked toe tap: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.tuckedToeTap.easier", defaultValue: "Bend your knees more so your heels tap closer to your hips.",
                           bundle: .module, comment: "Tucked toe tap: an easier version, as a short instruction")
        )
    }

    static var reverseCrunch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Reverse crunch", keyStem: "reverseCrunch",
            displayName: String(localized: "exercise.reverseCrunch.name", defaultValue: "Reverse crunch",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.reverseCrunch.cue1", defaultValue: "Lie on your back with your arms flat by your sides.",
                       bundle: .module, comment: "Reverse crunch: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.reverseCrunch.cue2", defaultValue: "Lift your bent knees until they're above your hips.",
                       bundle: .module, comment: "Reverse crunch: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.reverseCrunch.cue3", defaultValue: "Curl your hips off the floor, drawing your knees toward your chest.",
                       bundle: .module, comment: "Reverse crunch: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.reverseCrunch.cue4", defaultValue: "Lower your hips slowly back to the floor.",
                       bundle: .module, comment: "Reverse crunch: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.reverseCrunch.mistake", defaultValue: "Swinging the legs to throw the hips up.",
                            bundle: .module, comment: "Reverse crunch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.reverseCrunch.easier", defaultValue: "Make the curl smaller, lifting your hips only a little.",
                           bundle: .module, comment: "Reverse crunch: an easier version, as a short instruction")
        )
    }

    static var bicycleCrunch: ExerciseHowTo {
        ExerciseHowTo(
            name: "Bicycle crunch", keyStem: "bicycleCrunch",
            displayName: String(localized: "exercise.bicycleCrunch.name", defaultValue: "Bicycle crunch",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.bicycleCrunch.cue1", defaultValue: "Lie on your back, fingertips resting lightly by your head.",
                       bundle: .module, comment: "Bicycle crunch: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.bicycleCrunch.cue2", defaultValue: "Lift your shoulders and bring your knees above your hips.",
                       bundle: .module, comment: "Bicycle crunch: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.bicycleCrunch.cue3", defaultValue: "Turn one elbow toward the opposite knee as the other leg straightens.",
                       bundle: .module, comment: "Bicycle crunch: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.bicycleCrunch.cue4", defaultValue: "Switch sides in a smooth, steady rhythm.",
                       bundle: .module, comment: "Bicycle crunch: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.bicycleCrunch.mistake", defaultValue: "Rushing and pulling on the neck instead of turning the ribs.",
                            bundle: .module, comment: "Bicycle crunch: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.bicycleCrunch.easier", defaultValue: "Keep the straight leg higher off the floor, and go slowly.",
                           bundle: .module, comment: "Bicycle crunch: an easier version, as a short instruction")
        )
    }

    static var flutterKick: ExerciseHowTo {
        ExerciseHowTo(
            name: "Flutter kick", keyStem: "flutterKick",
            displayName: String(localized: "exercise.flutterKick.name", defaultValue: "Flutter kick",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.flutterKick.cue1", defaultValue: "Lie on your back, hands under your hips or by your sides.",
                       bundle: .module, comment: "Flutter kick: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.flutterKick.cue2", defaultValue: "Press your lower back down and lift both straight legs slightly.",
                       bundle: .module, comment: "Flutter kick: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.flutterKick.cue3", defaultValue: "Kick your legs up and down in turn, small and quick.",
                       bundle: .module, comment: "Flutter kick: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.flutterKick.cue4", defaultValue: "Feel it low in your stomach, not your lower back.",
                       bundle: .module, comment: "Flutter kick: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.flutterKick.cue5", defaultValue: "Breathe steadily the whole time; don't hold your breath.",
                       bundle: .module, comment: "Flutter kick: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.flutterKick.mistake", defaultValue: "Letting the lower back arch as the legs tire.",
                            bundle: .module, comment: "Flutter kick: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.flutterKick.easier", defaultValue: "Hold your legs higher, or bend your knees a little.",
                           bundle: .module, comment: "Flutter kick: an easier version, as a short instruction")
        )
    }

    static var heelTap: ExerciseHowTo {
        ExerciseHowTo(
            name: "Heel tap", keyStem: "heelTap",
            displayName: String(localized: "exercise.heelTap.name", defaultValue: "Heel tap",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.heelTap.cue1", defaultValue: "Lie on your back, knees bent, feet flat and hip-width apart.",
                       bundle: .module, comment: "Heel tap: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.heelTap.cue2", defaultValue: "Lift your head and shoulders a little off the floor.",
                       bundle: .module, comment: "Heel tap: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.heelTap.cue3", defaultValue: "Reach one hand toward the heel on that side, bending sideways.",
                       bundle: .module, comment: "Heel tap: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.heelTap.cue4", defaultValue: "Switch sides, keeping your shoulders up the whole time.",
                       bundle: .module, comment: "Heel tap: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.heelTap.mistake", defaultValue: "Dropping the head and shoulders back down between taps.",
                            bundle: .module, comment: "Heel tap: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.heelTap.easier", defaultValue: "Move your feet closer to your hips so the reach is shorter.",
                           bundle: .module, comment: "Heel tap: an easier version, as a short instruction")
        )
    }

    static var hollowRock: ExerciseHowTo {
        ExerciseHowTo(
            name: "Hollow rock", keyStem: "hollowRock",
            displayName: String(localized: "exercise.hollowRock.name", defaultValue: "Hollow rock",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.hollowRock.cue1", defaultValue: "Get into a hollow hold: lower back down, shoulders and legs lifted.",
                       bundle: .module, comment: "Hollow rock: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.hollowRock.cue2", defaultValue: "Reach your arms overhead and keep your legs together.",
                       bundle: .module, comment: "Hollow rock: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.hollowRock.cue3", defaultValue: "Rock gently toward your shoulders, then toward your hips.",
                       bundle: .module, comment: "Hollow rock: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.hollowRock.cue4", defaultValue: "Keep the same curved shape the whole time you rock.",
                       bundle: .module, comment: "Hollow rock: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.hollowRock.mistake", defaultValue: "Bending at the hips or knees so the shape breaks.",
                            bundle: .module, comment: "Hollow rock: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.hollowRock.easier", defaultValue: "Bend your knees and reach forward, or hold without rocking.",
                           bundle: .module, comment: "Hollow rock: an easier version, as a short instruction")
        )
    }

    static var plankShoulderTap: ExerciseHowTo {
        ExerciseHowTo(
            name: "Plank shoulder tap", keyStem: "plankShoulderTap",
            displayName: String(localized: "exercise.plankShoulderTap.name", defaultValue: "Plank shoulder tap",
                                bundle: .module, comment: "Exercise name shown on screen (bodyweight exercise)"),
            cues: [
                String(localized: "exercise.plankShoulderTap.cue1", defaultValue: "Start in a high plank, hands under your shoulders.",
                       bundle: .module, comment: "Plank shoulder tap: how-to cue 1 of 4, a short imperative step"),
                String(localized: "exercise.plankShoulderTap.cue2", defaultValue: "Set your feet a little wider than your hips.",
                       bundle: .module, comment: "Plank shoulder tap: how-to cue 2 of 4, a short imperative step"),
                String(localized: "exercise.plankShoulderTap.cue3", defaultValue: "Lift one hand to tap the opposite shoulder.",
                       bundle: .module, comment: "Plank shoulder tap: how-to cue 3 of 4, a short imperative step"),
                String(localized: "exercise.plankShoulderTap.cue4", defaultValue: "Keep your hips still and level, then switch hands.",
                       bundle: .module, comment: "Plank shoulder tap: how-to cue 4 of 4, a short imperative step"),
            ],
            mistake: String(localized: "exercise.plankShoulderTap.mistake", defaultValue: "Rocking the hips side to side with each tap.",
                            bundle: .module, comment: "Plank shoulder tap: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.plankShoulderTap.easier", defaultValue: "Set your feet wider, or rest your knees on the floor.",
                           bundle: .module, comment: "Plank shoulder tap: an easier version, as a short instruction")
        )
    }

    static var cableWoodchopper: ExerciseHowTo {
        ExerciseHowTo(
            name: "Cable woodchopper", keyStem: "cableWoodchopper",
            displayName: String(localized: "exercise.cableWoodchopper.name", defaultValue: "Cable woodchopper",
                                bundle: .module, comment: "Exercise name shown on screen (cable machine exercise)"),
            cues: [
                String(localized: "exercise.cableWoodchopper.cue1", defaultValue: "Set the cable high and stand side-on to the machine.",
                       bundle: .module, comment: "Cable woodchopper: how-to cue 1 of 5, a short imperative step"),
                String(localized: "exercise.cableWoodchopper.cue2", defaultValue: "Hold the handle in both hands above the shoulder nearest the machine.",
                       bundle: .module, comment: "Cable woodchopper: how-to cue 2 of 5, a short imperative step"),
                String(localized: "exercise.cableWoodchopper.cue3", defaultValue: "Pull it down across your body toward the opposite hip.",
                       bundle: .module, comment: "Cable woodchopper: how-to cue 3 of 5, a short imperative step"),
                String(localized: "exercise.cableWoodchopper.cue4", defaultValue: "Turn through your trunk and let the near foot pivot.",
                       bundle: .module, comment: "Cable woodchopper: how-to cue 4 of 5, a short imperative step"),
                String(localized: "exercise.cableWoodchopper.cue5", defaultValue: "Return slowly, then repeat facing the other way.",
                       bundle: .module, comment: "Cable woodchopper: how-to cue 5 of 5, a short imperative step"),
            ],
            mistake: String(localized: "exercise.cableWoodchopper.mistake", defaultValue: "Pulling with the arms alone while the trunk stays still.",
                            bundle: .module, comment: "Cable woodchopper: the one common mistake to avoid, as a short phrase"),
            easier: String(localized: "exercise.cableWoodchopper.easier", defaultValue: "Use a lighter weight and make the movement smaller.",
                           bundle: .module, comment: "Cable woodchopper: an easier version, as a short instruction")
        )
    }
}
