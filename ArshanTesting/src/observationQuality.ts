import { canonicalSurfaceKey } from "./memoryStore";
import { Observation } from "./observationPrompt";
import { SyntheticStateId } from "./syntheticScreens";

export interface ObservationQualityReport {
  state: SyntheticStateId;
  expectedSurface: string;
  observedSurface: string;
  passed: boolean;
  score: number;
  missingFacts: string[];
  presentFacts: string[];
}

const expectedFactsByState: Record<SyntheticStateId, {
  surface: string;
  facts: string[];
  minControls: number;
}> = {
  overview: {
    surface: "overview",
    minControls: 3,
    facts: ["Deployments", "failed deployment", "Checkout API"]
  },
  deployments: {
    surface: "deployments",
    minControls: 3,
    facts: ["Status", "Environment", "api-8f31", "Failed", "Production"]
  },
  "filters-open": {
    surface: "filters-open",
    minControls: 3,
    facts: ["Failed", "Ready", "Building", "Canceled", "Apply filters"]
  },
  "failed-detail": {
    surface: "failed-detail",
    minControls: 3,
    facts: ["api-8f31", "Build failed", "Missing DATABASE_URL", "View logs", "Redeploy"]
  },
  "layout-drift-overview": {
    surface: "overview",
    minControls: 3,
    facts: ["Deployments", "top navigation", "failed deployment", "Checkout API"]
  }
};

export function assessObservationQuality(observation: Observation, state: SyntheticStateId): ObservationQualityReport {
  const expected = expectedFactsByState[state];
  const corpus = observationCorpus(observation);
  const missingFacts = expected.facts.filter((fact) => !corpus.includes(fact.toLowerCase()));
  const presentFacts = expected.facts.filter((fact) => !missingFacts.includes(fact));
  const observedSurface = canonicalSurfaceKey(observation);
  const surfacePassed = observedSurface === expected.surface;
  const controlsPassed = observation.visibleControls.length >= expected.minControls;
  const passedChecks = [
    surfacePassed,
    controlsPassed,
    ...expected.facts.map((fact) => presentFacts.includes(fact))
  ].filter(Boolean).length;
  const totalChecks = 2 + expected.facts.length;

  return {
    state,
    expectedSurface: expected.surface,
    observedSurface,
    passed: surfacePassed && controlsPassed && missingFacts.length === 0,
    score: passedChecks / totalChecks,
    missingFacts,
    presentFacts
  };
}

function observationCorpus(observation: Observation): string {
  return [
    observation.app,
    observation.windowTitle,
    observation.surfaceId,
    observation.surfaceLabel,
    observation.summary,
    ...observation.visibleControls.flatMap((control) => [control.label, control.role, control.region]),
    ...observation.visibleEntities,
    ...observation.landmarks,
    ...observation.likelyAffordances,
    ...observation.uncertainty
  ].join(" ").toLowerCase();
}
