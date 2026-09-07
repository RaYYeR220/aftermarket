/**
 * The one projection every solid on this site is drawn through.
 *
 *   sx = (x - y) * cos30 * S
 *   sy = (x + y) * 0.30 * S - z * S
 *
 * `x` runs right-and-down, `y` runs left-and-down, `z` is up.
 *
 * The 0.30 depth factor is a deliberately low camera rather than a textbook
 * 0.5 isometric: at 0.5 the ceiling plate's overhang covers the headroom
 * underneath it, and the headroom is the one thing these drawings exist to
 * show. Do not "correct" it.
 */

export const SPREAD = Math.cos(Math.PI / 6);
export const DEPTH = 0.3;

export interface Projection {
  /** Pixels per scene unit. */
  scale: number;
  /** Where the scene origin sits inside the viewBox. */
  originX: number;
  originY: number;
}

export function projectPoint(p: Projection, x: number, y: number, z: number): readonly [number, number] {
  return [
    p.originX + (x - y) * SPREAD * p.scale,
    p.originY + (x + y) * DEPTH * p.scale - z * p.scale,
  ] as const;
}

/** A projected point as SVG path coordinates. */
export function pt(p: Projection, x: number, y: number, z: number): string {
  const [sx, sy] = projectPoint(p, x, y, z);
  return `${sx.toFixed(2)} ${sy.toFixed(2)}`;
}

/**
 * The three visible faces of an axis-aligned box: the top, the left face (the
 * `y = y1` plane) and the right face (the `x = x1` plane). Light falls from
 * above and from the left for every object on the page, so those three faces
 * always take the same three tints of one hue, lightest first.
 */
export interface BoxFaces {
  top: string;
  left: string;
  right: string;
}

export function box(
  p: Projection,
  x0: number,
  x1: number,
  y0: number,
  y1: number,
  z0: number,
  z1: number,
): BoxFaces {
  return {
    top: `M${pt(p, x0, y0, z1)}L${pt(p, x1, y0, z1)}L${pt(p, x1, y1, z1)}L${pt(p, x0, y1, z1)}Z`,
    left: `M${pt(p, x0, y1, z1)}L${pt(p, x1, y1, z1)}L${pt(p, x1, y1, z0)}L${pt(p, x0, y1, z0)}Z`,
    right: `M${pt(p, x1, y0, z1)}L${pt(p, x1, y1, z1)}L${pt(p, x1, y1, z0)}L${pt(p, x1, y0, z0)}Z`,
  };
}

/**
 * The transform that lays text into the left face plane, so a ticker reads as a
 * shelf-edge label rather than as a caption floating in front of the object.
 */
export function faceTextTransform(p: Projection, x: number, y: number, z: number): string {
  const [sx, sy] = projectPoint(p, x, y, z);
  return `matrix(${SPREAD.toFixed(4)} ${DEPTH.toFixed(4)} 0 1 ${sx.toFixed(2)} ${sy.toFixed(2)})`;
}

/** The transform that maps a unit circle onto the isometric floor, for contact shadows. */
export function floorEllipseTransform(p: Projection, cx: number, cy: number): string {
  const [sx, sy] = projectPoint(p, cx, cy, 0);
  const a = (SPREAD * p.scale).toFixed(4);
  const b = (DEPTH * p.scale).toFixed(4);
  return `matrix(${a} ${b} ${-Number(a)} ${b} ${sx.toFixed(2)} ${sy.toFixed(2)})`;
}
