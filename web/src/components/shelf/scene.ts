import { usdAuto } from "@/lib/format";

import type { ShelfModel } from "./model";
import { box, faceTextTransform, floorEllipseTransform, projectPoint, pt, type Projection } from "./projection";

/**
 * The isometric shelving system, emitted from the book.
 *
 * Everything is geometry: change a number in the model and the drawing changes,
 * because there is no artwork here to fall out of sync with it. Three zones
 * stack between four uprights --
 *
 *   solid blue   the balance drawn
 *   sage         headroom, capped by the ceiling plate at the borrowing limit
 *   wireframe    the same bays, empty: collateral this session will not lend
 *                against. Visible edges solid, hidden edges dashed, which is
 *                the drawing convention for a part you can see through.
 *
 * Colour never appears here as a literal. Every node carries a class name and
 * the class resolves a token, so the ramps stay in one file.
 */

export const SCENE_VIEWBOX = "170 28 1030 690";

const PROJECTION: Projection = { scale: 46, originX: 690, originY: 560 };

/** Scene dimensions, in units. */
const COLUMN_HEIGHT = 8.4;
const STACK_HALF = 2.45;
const GROUND_HALF = 4.0;
const GROUND_THICK = 0.34;
const UPRIGHT_OFFSET = 3.05;
const UPRIGHT_HALF = 0.13;
const UPRIGHT_TOP = 9.2;
const PLATE_HALF = 2.85;
const PLATE_THICK = 0.3;
const PIN_PITCH = 0.6;

const SIZE_VALUE = 13.5;
const SIZE_KEY = 11;
const SIZE_TICKER = 12;

export type SceneClass =
  | "groundTop"
  | "groundLeft"
  | "groundRight"
  | "groundLight"
  | "groundGrid"
  | "groundOutline"
  | "shadowSoft"
  | "shadowContact"
  | "uprightTop"
  | "uprightLeft"
  | "uprightRight"
  | "uprightPin"
  | "uprightHighlight"
  | "drawTop"
  | "drawLeft"
  | "drawRight"
  | "drawEdge"
  | "drawCorner"
  | "drawLabel"
  | "headTop"
  | "headLeft"
  | "headRight"
  | "headEdge"
  | "headCorner"
  | "headLabel"
  | "plateTop"
  | "plateLeft"
  | "plateRight"
  | "plateEdge"
  | "plateSeam"
  | "wire"
  | "wireHidden"
  | "wireLabel"
  | "occlusion"
  | "levelLine"
  | "leader"
  | "leaderDot"
  | "leaderDotLimit"
  | "leaderDotDrawn"
  | "leaderDotHead"
  | "construction"
  | "annotationKey"
  | "annotationValue";

export type SceneNode =
  | { kind: "path"; id: string; d: string; cls: SceneClass; opacity?: number }
  | {
      kind: "text";
      id: string;
      content: string;
      cls: SceneClass;
      size: number;
      x?: number | undefined;
      y?: number | undefined;
      transform?: string | undefined;
      anchor?: "start" | "middle" | "end" | undefined;
    }
  | { kind: "circle"; id: string; cx: number; cy: number; r: number; cls: SceneClass }
  | { kind: "ellipse"; id: string; r: number; cls: SceneClass; transform: string; opacity?: number };

export interface ShelfScene {
  body: SceneNode[];
  /** Leader callouts, the drop dimension and the title block: hidden on narrow screens. */
  annotations: SceneNode[];
  /** What the scene currently reads, for the legend that replaces the callouts on narrow screens. */
  figures: {
    /** `null` when the basket is unpriced: there is no ceiling, rather than a ceiling of zero. */
    limitUsd: number | null;
    drawnUsd: number;
    /** `null` for the same reason as `limitUsd`. */
    headroomUsd: number | null;
    idleUsd: number;
    advanceRate: number;
  };
}

function solid(
  id: string,
  faces: { top: string; left: string; right: string },
  cls: { top: SceneClass; left: SceneClass; right: SceneClass },
): SceneNode[] {
  return [
    { kind: "path", id: `${id}-r`, d: faces.right, cls: cls.right },
    { kind: "path", id: `${id}-l`, d: faces.left, cls: cls.left },
    { kind: "path", id: `${id}-t`, d: faces.top, cls: cls.top },
  ];
}

/**
 * Stepped ambient occlusion hanging below a horizontal seam. Fixed in scene
 * units rather than scaled to the block, so it behaves like real contact
 * shading instead of growing with whatever it sits under.
 */
function occlusion(id: string, half: number, z: number, strength: number): SceneNode[] {
  const steps = [0.34, 0.22, 0.13, 0.06];
  const nodes: SceneNode[] = [];
  steps.forEach((height, index) => {
    const opacity = 0.055 * strength;
    nodes.push({
      kind: "path",
      id: `${id}-l${index}`,
      d: `M${pt(PROJECTION, -half, half, z)}L${pt(PROJECTION, half, half, z)}L${pt(PROJECTION, half, half, z - height)}L${pt(PROJECTION, -half, half, z - height)}Z`,
      cls: "occlusion",
      opacity,
    });
    nodes.push({
      kind: "path",
      id: `${id}-r${index}`,
      d: `M${pt(PROJECTION, half, -half, z)}L${pt(PROJECTION, half, half, z)}L${pt(PROJECTION, half, half, z - height)}L${pt(PROJECTION, half, -half, z - height)}Z`,
      cls: "occlusion",
      opacity,
    });
  });
  return nodes;
}

function upright(id: string, sx: number, sy: number): SceneNode[] {
  const faces = box(
    PROJECTION,
    sx - UPRIGHT_HALF,
    sx + UPRIGHT_HALF,
    sy - UPRIGHT_HALF,
    sy + UPRIGHT_HALF,
    0,
    UPRIGHT_TOP,
  );
  const nodes = solid(id, faces, { top: "uprightTop", left: "uprightLeft", right: "uprightRight" });
  let index = 0;
  for (let z = PIN_PITCH; z < UPRIGHT_TOP - 0.2; z += PIN_PITCH) {
    nodes.push({
      kind: "path",
      id: `${id}-pin${index}`,
      d: `M${pt(PROJECTION, sx - UPRIGHT_HALF + 0.03, sy + UPRIGHT_HALF, z)}L${pt(PROJECTION, sx + UPRIGHT_HALF - 0.03, sy + UPRIGHT_HALF, z)}`,
      cls: "uprightPin",
    });
    index += 1;
  }
  nodes.push({
    kind: "path",
    id: `${id}-hl`,
    d: `M${pt(PROJECTION, sx + UPRIGHT_HALF, sy + UPRIGHT_HALF, 0)}L${pt(PROJECTION, sx + UPRIGHT_HALF, sy + UPRIGHT_HALF, UPRIGHT_TOP)}`,
    cls: "uprightHighlight",
  });
  return nodes;
}

function leaderCallout(
  id: string,
  z: number,
  side: -1 | 1,
  key: string,
  value: string,
  dot: SceneClass,
): SceneNode[] {
  const [ax, ay] = projectPoint(
    PROJECTION,
    side < 0 ? -STACK_HALF : STACK_HALF,
    side < 0 ? STACK_HALF : -STACK_HALF,
    z,
  );
  const railX = side < 0 ? 310 : 1052;
  const textX = side < 0 ? railX - 12 : railX + 12;
  const anchor = side < 0 ? "end" : "start";
  return [
    {
      kind: "path",
      id: `${id}-line`,
      d: `M${ax.toFixed(1)} ${ay.toFixed(1)}L${railX} ${ay.toFixed(1)}`,
      cls: "leader",
    },
    { kind: "circle", id: `${id}-dot`, cx: Number(ax.toFixed(1)), cy: Number(ay.toFixed(1)), r: 2.6, cls: dot },
    {
      kind: "text",
      id: `${id}-key`,
      content: key,
      cls: "annotationKey",
      size: SIZE_KEY,
      x: textX,
      y: Number((ay - 7).toFixed(1)),
      anchor,
    },
    {
      kind: "text",
      id: `${id}-val`,
      content: value,
      cls: "annotationValue",
      size: SIZE_VALUE,
      x: textX,
      y: Number((ay + SIZE_VALUE + 3).toFixed(1)),
      anchor,
    },
  ];
}

export interface BuildSceneOptions {
  model: ShelfModel;
  /** Where the ceiling plate currently sits, as a fraction of the full column. */
  limitFraction: number;
  /**
   * Draw the column with no ceiling at all.
   *
   * This is the state where an oracle in the basket refuses to publish a mark. The engine reports
   * no borrowing power for the whole basket, not a smaller one, so a plate drawn at any height
   * would assert a limit the protocol is not standing behind. Instead the debt stays solid -- it is
   * real and still owed -- and everything above it is an empty cage with nothing resting on it.
   */
  frozen?: boolean | undefined;
}

export function buildShelfScene({ model, limitFraction, frozen = false }: BuildSceneOptions): ShelfScene {
  const body: SceneNode[] = [];
  const annotations: SceneNode[] = [];

  const plateZ = limitFraction * COLUMN_HEIGHT;
  const drawZ = model.drawnFraction * COLUMN_HEIGHT;
  /** Material above the plate rests on it, so the column is lifted by the plate's own thickness. */
  const liftedZ = (z: number) => (z <= plateZ ? z : z + PLATE_THICK);

  // -- ground plate ---------------------------------------------------------
  const ground = box(PROJECTION, -GROUND_HALF, GROUND_HALF, -GROUND_HALF, GROUND_HALF, -GROUND_THICK, 0);
  body.push(...solid("ground", ground, { top: "groundTop", left: "groundLeft", right: "groundRight" }));
  body.push({ kind: "path", id: "ground-light", d: ground.top, cls: "groundLight" });
  for (let i = -5; i <= 5; i += 1) {
    body.push({
      kind: "path",
      id: `grid-x${i}`,
      d: `M${pt(PROJECTION, i, -GROUND_HALF + 0.6, 0)}L${pt(PROJECTION, i, GROUND_HALF - 0.6, 0)}`,
      cls: "groundGrid",
    });
    body.push({
      kind: "path",
      id: `grid-y${i}`,
      d: `M${pt(PROJECTION, -GROUND_HALF + 0.6, i, 0)}L${pt(PROJECTION, GROUND_HALF - 0.6, i, 0)}`,
      cls: "groundGrid",
    });
  }
  body.push({ kind: "path", id: "ground-outline", d: ground.top, cls: "groundOutline" });

  // -- shadows: the plate's own shadow tightens as it descends ---------------
  const heightAbove = Math.max(plateZ, 0.2);
  body.push({
    kind: "ellipse",
    id: "shadow-plate",
    r: 0.9 + heightAbove * 0.26,
    cls: "shadowSoft",
    transform: floorEllipseTransform(PROJECTION, 0, 0),
    opacity: Number(Math.max(0, 1.02 - heightAbove * 0.052).toFixed(3)),
  });
  body.push({
    kind: "ellipse",
    id: "shadow-stack",
    r: STACK_HALF * 1.5,
    cls: "shadowContact",
    transform: floorEllipseTransform(PROJECTION, 0.18, 0.18),
  });

  // -- the three uprights behind the stack -----------------------------------
  body.push(...upright("upright-bl", -UPRIGHT_OFFSET, -UPRIGHT_OFFSET));
  body.push(...upright("upright-br", UPRIGHT_OFFSET, -UPRIGHT_OFFSET));
  body.push(...upright("upright-fl", -UPRIGHT_OFFSET, UPRIGHT_OFFSET));

  // -- the column ------------------------------------------------------------
  const seams: number[] = [0];
  let running = 0;
  for (const bay of model.bays) {
    running += bay.valueUsd;
    seams.push(running / model.basketUsd);
  }

  const cuts = [0, model.drawnFraction, limitFraction, 1, ...seams]
    .filter((value) => value >= 0 && value <= 1)
    .sort((a, b) => a - b)
    .filter((value, index, all) => index === 0 || value - (all[index - 1] ?? 0) > 1e-4);

  const litEdges: SceneNode[] = [];
  const wire: SceneNode[] = [];

  for (let i = 0; i < cuts.length - 1; i += 1) {
    const from = cuts[i] ?? 0;
    const to = cuts[i + 1] ?? 0;
    const z0 = liftedZ(from * COLUMN_HEIGHT);
    const z1 = liftedZ(to * COLUMN_HEIGHT);
    const faces = box(PROJECTION, -STACK_HALF, STACK_HALF, -STACK_HALF, STACK_HALF, z0, z1);
    const topEdge = `M${pt(PROJECTION, -STACK_HALF, STACK_HALF, z1)}L${pt(PROJECTION, STACK_HALF, STACK_HALF, z1)}L${pt(PROJECTION, STACK_HALF, -STACK_HALF, z1)}`;
    const frontCorner = `M${pt(PROJECTION, STACK_HALF, STACK_HALF, z0)}L${pt(PROJECTION, STACK_HALF, STACK_HALF, z1)}`;

    if (to <= model.drawnFraction + 1e-6) {
      body.push(...solid(`seg${i}`, faces, { top: "drawTop", left: "drawLeft", right: "drawRight" }));
      body.push(...occlusion(`seg${i}-ao`, STACK_HALF, z1, 1));
      litEdges.push({ kind: "path", id: `seg${i}-edge`, d: topEdge, cls: "drawEdge" });
      litEdges.push({ kind: "path", id: `seg${i}-corner`, d: frontCorner, cls: "drawCorner" });
    } else if (to <= limitFraction + 1e-6) {
      body.push(...solid(`seg${i}`, faces, { top: "headTop", left: "headLeft", right: "headRight" }));
      body.push(...occlusion(`seg${i}-ao`, STACK_HALF, z1, 0.8));
      litEdges.push({ kind: "path", id: `seg${i}-edge`, d: topEdge, cls: "headEdge" });
      litEdges.push({ kind: "path", id: `seg${i}-corner`, d: frontCorner, cls: "headCorner" });
    } else {
      if (to > 1 - 1e-6) {
        wire.push({
          kind: "path",
          id: `seg${i}-hidden`,
          d: `M${pt(PROJECTION, -STACK_HALF, -STACK_HALF, z1)}L${pt(PROJECTION, -STACK_HALF, STACK_HALF, z1)}M${pt(PROJECTION, -STACK_HALF, -STACK_HALF, z1)}L${pt(PROJECTION, STACK_HALF, -STACK_HALF, z1)}M${pt(PROJECTION, -STACK_HALF, -STACK_HALF, liftedZ(limitFraction * COLUMN_HEIGHT) + PLATE_THICK)}L${pt(PROJECTION, -STACK_HALF, -STACK_HALF, z1)}`,
          cls: "wireHidden",
        });
      }
      wire.push({ kind: "path", id: `seg${i}-wl`, d: faces.left, cls: "wire" });
      wire.push({ kind: "path", id: `seg${i}-wr`, d: faces.right, cls: "wire" });
      wire.push({ kind: "path", id: `seg${i}-we`, d: topEdge, cls: "wire" });
    }
  }

  body.push(...occlusion("plate-ao", STACK_HALF, plateZ, 1.6));
  body.push({
    kind: "path",
    id: "contact-l",
    d: `M${pt(PROJECTION, -STACK_HALF, STACK_HALF, 0.34)}L${pt(PROJECTION, STACK_HALF, STACK_HALF, 0.34)}L${pt(PROJECTION, STACK_HALF, STACK_HALF, 0)}L${pt(PROJECTION, -STACK_HALF, STACK_HALF, 0)}Z`,
    cls: "occlusion",
    opacity: 0.075,
  });
  body.push({
    kind: "path",
    id: "contact-r",
    d: `M${pt(PROJECTION, STACK_HALF, -STACK_HALF, 0.34)}L${pt(PROJECTION, STACK_HALF, STACK_HALF, 0.34)}L${pt(PROJECTION, STACK_HALF, STACK_HALF, 0)}L${pt(PROJECTION, STACK_HALF, -STACK_HALF, 0)}Z`,
    cls: "occlusion",
    opacity: 0.075,
  });
  body.push(...litEdges);
  body.push({
    kind: "path",
    id: "draw-level",
    d: `M${pt(PROJECTION, -STACK_HALF, STACK_HALF, drawZ)}L${pt(PROJECTION, STACK_HALF, STACK_HALF, drawZ)}L${pt(PROJECTION, STACK_HALF, -STACK_HALF, drawZ)}`,
    cls: "levelLine",
  });

  // -- a ticker in the plane of the left face, on every bay tall enough to
  //    carry one --------------------------------------------------------------
  model.bays.forEach((bay, index) => {
    const from = seams[index] ?? 0;
    const to = seams[index + 1] ?? 0;
    const visibleTop = Math.min(to, from >= limitFraction ? to : limitFraction);
    if ((visibleTop - from) * COLUMN_HEIGHT * PROJECTION.scale < 30) return;
    const z = liftedZ(from * COLUMN_HEIGHT) + 0.34;
    const cls: SceneClass =
      from >= limitFraction ? "wireLabel" : from + 0.02 <= model.drawnFraction ? "drawLabel" : "headLabel";
    const node: SceneNode = {
      kind: "text",
      id: `ticker-${bay.ticker}`,
      content: bay.underlying,
      cls,
      size: SIZE_TICKER,
      transform: faceTextTransform(PROJECTION, -STACK_HALF + 0.24, STACK_HALF, z),
    };
    if (from >= limitFraction) wire.push(node);
    else body.push(node);
  });

  // -- the ceiling plate ------------------------------------------------------
  if (!frozen) {
    const plate = box(PROJECTION, -PLATE_HALF, PLATE_HALF, -PLATE_HALF, PLATE_HALF, plateZ, plateZ + PLATE_THICK);
    body.push(...solid("plate", plate, { top: "plateTop", left: "plateLeft", right: "plateRight" }));
    body.push({
      kind: "path",
      id: "plate-seam",
      d: `M${pt(PROJECTION, PLATE_HALF, PLATE_HALF, plateZ)}L${pt(PROJECTION, PLATE_HALF, PLATE_HALF, plateZ + PLATE_THICK)}`,
      cls: "plateSeam",
    });
    body.push({
      kind: "path",
      id: "plate-edge",
      d: `M${pt(PROJECTION, -PLATE_HALF, PLATE_HALF, plateZ + PLATE_THICK)}L${pt(PROJECTION, PLATE_HALF, PLATE_HALF, plateZ + PLATE_THICK)}L${pt(PROJECTION, PLATE_HALF, -PLATE_HALF, plateZ + PLATE_THICK)}`,
      cls: "plateEdge",
    });
    body.push({
      kind: "path",
      id: "plate-edge-front",
      d: `M${pt(PROJECTION, PLATE_HALF, PLATE_HALF, plateZ + PLATE_THICK)}L${pt(PROJECTION, PLATE_HALF, PLATE_HALF, plateZ)}`,
      cls: "plateEdge",
    });
  }

  body.push(...wire);

  // -- where the plate sits when the market is open, and the drop between -----
  const openZ = model.limitFractionOpen * COLUMN_HEIGHT;
  const openTop = openZ + PLATE_THICK;
  const plateTop = plateZ + PLATE_THICK;
  if (!frozen && Math.abs(openZ - plateZ) > 0.1) {
    const ghost = box(PROJECTION, -PLATE_HALF, PLATE_HALF, -PLATE_HALF, PLATE_HALF, openZ, openTop);
    body.push({ kind: "path", id: "ghost-plate", d: ghost.top, cls: "construction" });

    const [ghostX, ghostY] = projectPoint(PROJECTION, -PLATE_HALF, PLATE_HALF, openTop);
    annotations.push({
      kind: "path",
      id: "ghost-leader",
      d: `M${ghostX.toFixed(1)} ${ghostY.toFixed(1)}L${(ghostX - 46).toFixed(1)} ${ghostY.toFixed(1)}`,
      cls: "leader",
    });
    annotations.push({
      kind: "text",
      id: "ghost-label",
      content: `open · ${Math.round(model.advanceOpen * 100)}%`,
      cls: "annotationKey",
      size: SIZE_KEY,
      x: Number((ghostX - 54).toFixed(1)),
      y: Number((ghostY + 3.5).toFixed(1)),
      anchor: "end",
    });

    const dimX = projectPoint(PROJECTION, PLATE_HALF, -PLATE_HALF, openTop)[0] + 26;
    const y1 = projectPoint(PROJECTION, 0, 0, openTop)[1];
    const y2 = projectPoint(PROJECTION, 0, 0, plateTop)[1];
    annotations.push({
      kind: "path",
      id: "drop-dim",
      d: `M${dimX} ${y1.toFixed(1)}L${dimX} ${y2.toFixed(1)}M${dimX - 5} ${y1.toFixed(1)}L${dimX + 5} ${y1.toFixed(1)}M${dimX - 5} ${y2.toFixed(1)}L${dimX + 5} ${y2.toFixed(1)}`,
      cls: "leader",
    });
    annotations.push({
      kind: "path",
      id: "drop-arrows",
      d: `M${dimX} ${(y2 - 1).toFixed(1)}l-3.2 -8l6.4 0Z M${dimX} ${(y1 + 1).toFixed(1)}l-3.2 8l6.4 0Z`,
      cls: "leaderDot",
    });
    annotations.push({
      kind: "text",
      id: "drop-key",
      content: "the drop",
      cls: "annotationKey",
      size: SIZE_KEY,
      x: dimX + 9,
      y: Number(((y1 + y2) / 2 - 4).toFixed(1)),
    });
    annotations.push({
      kind: "text",
      id: "drop-value",
      content: `-${usdAuto(model.lendableUsd * (model.advanceOpen - model.advanceClosed))}`,
      cls: "annotationValue",
      size: SIZE_VALUE,
      x: dimX + 9,
      y: Number(((y1 + y2) / 2 + SIZE_VALUE + 1).toFixed(1)),
    });
  }

  // -- the front upright, in front of everything -----------------------------
  body.push(...upright("upright-fr", UPRIGHT_OFFSET, UPRIGHT_OFFSET));

  // -- dimension callouts, both flanks, like a parts drawing -----------------
  const advanceRate = limitFraction >= (model.limitFractionOpen + model.limitFractionClosed) / 2
    ? model.advanceOpen
    : model.advanceClosed;
  const limitUsd = limitFraction * model.basketUsd;
  const headroomUsd = limitUsd - model.drawnUsd;
  const idleUsd = model.basketUsd - limitUsd;

  if (frozen) {
    annotations.push(
      ...leaderCallout("cl-limit", COLUMN_HEIGHT * 0.5, -1, "borrowing limit", "no defensible mark", "leaderDot"),
    );
  } else {
    annotations.push(
      ...leaderCallout("cl-limit", plateZ + PLATE_THICK / 2, -1, "borrowing limit", usdAuto(limitUsd), "leaderDotLimit"),
    );
  }
  annotations.push(...leaderCallout("cl-drawn", drawZ, -1, "drawn", usdAuto(model.drawnUsd), "leaderDotDrawn"));
  if (!frozen && plateZ - drawZ > 0.5) {
    annotations.push(
      ...leaderCallout("cl-head", (drawZ + plateZ) / 2, 1, "headroom", usdAuto(headroomUsd), "leaderDotHead"),
    );
  }
  annotations.push(
    ...leaderCallout(
      "cl-idle",
      frozen ? COLUMN_HEIGHT * 0.86 : plateZ + PLATE_THICK + (COLUMN_HEIGHT - plateZ) * 0.74,
      1,
      "not lent against",
      // A frozen basket has no defended total, so the callout names the extent rather than
      // printing a dollar figure assembled from marks the protocol will not publish.
      frozen ? "the whole basket" : usdAuto(idleUsd),
      "leaderDot",
    ),
  );

  // -- title block ------------------------------------------------------------
  annotations.push({ kind: "path", id: "title-rule", d: "M196 656L196 690", cls: "leader" });
  annotations.push({
    kind: "text",
    id: "title-key",
    content: model.title.key,
    cls: "annotationKey",
    size: SIZE_KEY,
    x: 208,
    y: 670,
  });
  annotations.push({
    kind: "text",
    id: "title-value",
    content: model.title.value,
    cls: "annotationValue",
    size: 12.5,
    x: 208,
    y: 687,
  });

  return {
    body,
    annotations,
    figures: {
      limitUsd: frozen ? null : limitUsd,
      drawnUsd: model.drawnUsd,
      headroomUsd: frozen ? null : headroomUsd,
      idleUsd: frozen ? model.basketUsd - model.drawnUsd : idleUsd,
      advanceRate,
    },
  };
}
