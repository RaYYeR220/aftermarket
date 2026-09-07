import type { ReactElement } from "react";

import { box, projectPoint, pt, type Projection } from "./projection";
import styles from "./scene.module.css";

/**
 * The motif again, smaller: four readings stacked on the same base plate, and
 * the plate they add up to resting above them on dashed risers.
 *
 * Same projection, same light direction, same three tints per solid as the hero
 * object -- so the drawing that explains the mechanism is visibly the same piece
 * of furniture as the one that states it. The viewBox is sized so the leader
 * labels render at about the same size as the surrounding prose rather than
 * shrinking with the object.
 */

const PROJECTION: Projection = { scale: 30, originX: 150, originY: 200 };

const GROUND_HALF = 2.55;
const GROUND_THICK = 0.24;
const SLAB_HALF = 1.85;
const SLAB_THICK = 0.62;
const SLAB_GAP = 0.2;
const PLATE_HALF = 2.25;
const PLATE_THICK = 0.28;
const PLATE_Z = 4 * (SLAB_THICK + SLAB_GAP) + 0.55;

const LEADER_X = 292;
const LABEL_X = LEADER_X + 11;
const SIZE_KEY = 13.5;
const SIZE_NOTE = 11.5;

/**
 * Bottom of the stack first: the calendar decides which tolerances the three
 * readings above it are judged by. What each one contributes is spelled out in
 * the prose beside the drawing, so the leaders carry a name and nothing else.
 */
const SOURCES = ["NYSE calendar", "B20 multiplier", "Aerodrome TWAP", "Chainlink feed"] as const;

export function SourceFigure() {
  const nodes: ReactElement[] = [];

  const ground = box(PROJECTION, -GROUND_HALF, GROUND_HALF, -GROUND_HALF, GROUND_HALF, -GROUND_THICK, 0);
  nodes.push(
    <path key="g-r" d={ground.right} className={styles.groundRight} />,
    <path key="g-l" d={ground.left} className={styles.groundLeft} />,
    <path key="g-t" d={ground.top} className={styles.groundTop} />,
    <path key="g-o" d={ground.top} className={styles.groundOutline} />,
  );

  SOURCES.forEach((label, index) => {
    const z0 = index * (SLAB_THICK + SLAB_GAP);
    const z1 = z0 + SLAB_THICK;
    const faces = box(PROJECTION, -SLAB_HALF, SLAB_HALF, -SLAB_HALF, SLAB_HALF, z0, z1);
    nodes.push(
      <path key={`s${index}-r`} d={faces.right} className={styles.uprightRight} />,
      <path key={`s${index}-l`} d={faces.left} className={styles.uprightLeft} />,
      <path key={`s${index}-t`} d={faces.top} className={styles.uprightTop} />,
    );

    const [ax, ay] = projectPoint(PROJECTION, SLAB_HALF, -SLAB_HALF, z0 + SLAB_THICK / 2);
    nodes.push(
      <path
        key={`s${index}-lead`}
        d={`M${ax.toFixed(1)} ${ay.toFixed(1)}L${LEADER_X} ${ay.toFixed(1)}`}
        className={styles.leader}
      />,
      <circle key={`s${index}-dot`} cx={ax.toFixed(1)} cy={ay.toFixed(1)} r={2.4} className={styles.leaderDot} />,
      <text
        key={`s${index}-key`}
        x={LABEL_X}
        y={(ay + 4).toFixed(1)}
        fontSize={SIZE_KEY}
        className={styles.annotationValue}
      >
        {label}
      </text>,
    );
  });

  // The readings do not touch the plate: it is derived from them, and the dashed
  // risers say so.
  const topSlabZ = 4 * (SLAB_THICK + SLAB_GAP) - SLAB_GAP;
  for (const [x, y] of [
    [-SLAB_HALF, SLAB_HALF],
    [SLAB_HALF, SLAB_HALF],
    [SLAB_HALF, -SLAB_HALF],
  ] as const) {
    nodes.push(
      <path
        key={`riser-${x}-${y}`}
        d={`M${pt(PROJECTION, x, y, topSlabZ)}L${pt(PROJECTION, x, y, PLATE_Z)}`}
        className={styles.construction}
      />,
    );
  }

  const plate = box(PROJECTION, -PLATE_HALF, PLATE_HALF, -PLATE_HALF, PLATE_HALF, PLATE_Z, PLATE_Z + PLATE_THICK);
  nodes.push(
    <path key="p-r" d={plate.right} className={styles.plateRight} />,
    <path key="p-l" d={plate.left} className={styles.plateLeft} />,
    <path key="p-t" d={plate.top} className={styles.plateTop} />,
    <path
      key="p-e"
      d={`M${pt(PROJECTION, -PLATE_HALF, PLATE_HALF, PLATE_Z + PLATE_THICK)}L${pt(PROJECTION, PLATE_HALF, PLATE_HALF, PLATE_Z + PLATE_THICK)}L${pt(PROJECTION, PLATE_HALF, -PLATE_HALF, PLATE_Z + PLATE_THICK)}`}
      className={styles.plateEdge}
    />,
  );

  const [px, py] = projectPoint(PROJECTION, PLATE_HALF, -PLATE_HALF, PLATE_Z + PLATE_THICK / 2);
  nodes.push(
    <path key="p-lead" d={`M${px.toFixed(1)} ${py.toFixed(1)}L${LEADER_X} ${py.toFixed(1)}`} className={styles.leader} />,
    <circle key="p-dot" cx={px.toFixed(1)} cy={py.toFixed(1)} r={2.4} className={styles.leaderDotLimit} />,
    <text key="p-key" x={LABEL_X} y={(py - 3).toFixed(1)} fontSize={SIZE_KEY} className={styles.annotationValue}>
      One mark
    </text>,
    <text key="p-note" x={LABEL_X} y={(py + 12).toFixed(1)} fontSize={SIZE_NOTE} className={styles.annotationKey}>
      or a refusal
    </text>,
  );

  return (
    <svg
      className={styles.svgFlat}
      viewBox="12 28 468 236"
      role="img"
      aria-label="An isometric drawing: four slabs stacked on a base plate, one for each reading the oracle takes — the NYSE calendar, the B20 multiplier, the Aerodrome time-weighted price and the Chainlink reference feed. A blue plate rests above them on dashed risers: the single mark those four readings add up to, or the refusal they produce instead."
    >
      {nodes}
    </svg>
  );
}
