//
//  ContextResolvedIntent.swift
//  Agent in the Notch
//
//  Phase 5b: the legacy `ContextIntentResolver` (Haiku-based pre-resolution
//  pass) and its outcome log were removed. The intent shape, however, is still
//  the typed payload `ComputerUseHarness.Input.resolvedIntent` consumes — so we
//  keep the three value types here as a transport-only contract.
//
//  AgentSession.mapToLegacyIntent(...) bridges the Selector's `CIntent` (see
//  ContextSchema.swift) into this shape. Phase 5c (a follow-up) is expected to
//  retype the harness Input to take `CIntent` directly and delete these types.
//

import Foundation

public struct ContextResolvedIntent: Codable, Sendable {
    public let verb: String
    public let target: String?
    public let resolvedEntities: [ContextEntityResolution]
    public let candidateRecipes: [ContextRecipeMatch]
    public let inferredGoal: String
    public let confidence: Double
    public let resolverLatencyMs: Int
    public let usedFallback: Bool

    public init(
        verb: String,
        target: String?,
        resolvedEntities: [ContextEntityResolution],
        candidateRecipes: [ContextRecipeMatch],
        inferredGoal: String,
        confidence: Double,
        resolverLatencyMs: Int,
        usedFallback: Bool
    ) {
        self.verb = verb
        self.target = target
        self.resolvedEntities = resolvedEntities
        self.candidateRecipes = candidateRecipes
        self.inferredGoal = inferredGoal
        self.confidence = confidence
        self.resolverLatencyMs = resolverLatencyMs
        self.usedFallback = usedFallback
    }
}

public struct ContextEntityResolution: Codable, Sendable {
    public let userPhrase: String
    public let entityID: String?
    public let entityLabel: String?
    public let entityType: String?
    public let confidence: Double
    public let evidence: String

    public init(
        userPhrase: String,
        entityID: String?,
        entityLabel: String?,
        entityType: String?,
        confidence: Double,
        evidence: String
    ) {
        self.userPhrase = userPhrase
        self.entityID = entityID
        self.entityLabel = entityLabel
        self.entityType = entityType
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct ContextRecipeMatch: Codable, Sendable {
    public let recipeID: String
    public let recipeName: String
    public let appKey: String
    public let fromSurfaceID: String?
    public let stepsProse: [String]
    public let matchScore: Double

    public init(
        recipeID: String,
        recipeName: String,
        appKey: String,
        fromSurfaceID: String?,
        stepsProse: [String],
        matchScore: Double
    ) {
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.appKey = appKey
        self.fromSurfaceID = fromSurfaceID
        self.stepsProse = stepsProse
        self.matchScore = matchScore
    }
}
