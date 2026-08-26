import Foundation

/// Bundle-relative source-of-truth for branded inhabitants. Keeping these
/// descriptors together makes provenance coverage and frame-count checks
/// mechanical instead of scattering asset strings through scene direction.
enum CompanionActorSpriteCatalog {
    static let pidgey = CompanionActorSprite(
        resource: "Pokemon/actors/pidgey.png",
        frameCount: 24,
        framesPerSecond: 12,
        facesRight: false
    )

    static let oldSchoolPeople = [
        CompanionActorSprite(
            resource: "OldSchoolRuneScape/Actors/man-blue.png",
            facesRight: true
        ),
        CompanionActorSprite(
            resource: "OldSchoolRuneScape/Actors/man-red.png",
            facesRight: true
        ),
        CompanionActorSprite(
            resource: "OldSchoolRuneScape/Actors/man-pink.png",
            facesRight: true
        )
    ]
    static let oldSchoolChicken = CompanionActorSprite(
        resource: "OldSchoolRuneScape/Actors/chicken.png",
        facesRight: false
    )
    static let oldSchoolSeagull = CompanionActorSprite(
        resource: "OldSchoolRuneScape/Actors/seagull.png",
        facesRight: false
    )

    static let ageVillagers = [
        CompanionActorSprite(
            resource: "AgeOfEmpiresII/actors/villager-m-walk.png",
            frameCount: 14,
            framesPerSecond: 10,
            facesRight: true
        ),
        CompanionActorSprite(
            resource: "AgeOfEmpiresII/actors/villager-f-walk.png",
            frameCount: 15,
            framesPerSecond: 10,
            facesRight: true
        )
    ]
    static let ageSheep = CompanionActorSprite(
        resource: "AgeOfEmpiresII/actors/sheep.png",
        facesRight: false
    )
    static let ageHawk = CompanionActorSprite(
        resource: "AgeOfEmpiresII/actors/hawk.png",
        frameCount: 10,
        framesPerSecond: 10,
        facesRight: false
    )

    static let minecraftChicken = minecraft("chicken", facesRight: false)
    static let minecraftPig = minecraft("pig", facesRight: false)
    static let minecraftVillager = minecraft("villager", facesRight: false)
    static let minecraftBat = minecraft(
        "bat",
        frameCount: 25,
        framesPerSecond: 12,
        facesRight: false
    )
    static let minecraftGoat = minecraft("goat", facesRight: false)
    static let minecraftPiglin = minecraft("piglin", facesRight: false)
    static let minecraftHoglin = minecraft("hoglin", facesRight: false)
    static let minecraftSilverfish = minecraft(
        "silverfish",
        frameCount: 14,
        framesPerSecond: 12,
        facesRight: true
    )

    private static func minecraft(
        _ name: String,
        frameCount: Int = 1,
        framesPerSecond: Double = 0,
        facesRight: Bool
    ) -> CompanionActorSprite {
        CompanionActorSprite(
            resource: "Minecraft/actors/\(name).png",
            frameCount: frameCount,
            framesPerSecond: framesPerSecond,
            facesRight: facesRight
        )
    }
}
