import type { ReactElement } from "react";

import styles from "./scene.module.css";
import { SCENE_VIEWBOX, type SceneNode, type ShelfScene } from "./scene";

function renderNode(node: SceneNode): ReactElement {
  const cls = styles[node.cls];
  switch (node.kind) {
    case "path":
      return <path key={node.id} d={node.d} className={cls} opacity={node.opacity} />;
    case "circle":
      return <circle key={node.id} cx={node.cx} cy={node.cy} r={node.r} className={cls} />;
    case "ellipse":
      return (
        <circle
          key={node.id}
          cx={0}
          cy={0}
          r={node.r}
          className={cls}
          transform={node.transform}
          opacity={node.opacity}
        />
      );
    case "text":
      return (
        <text
          key={node.id}
          className={cls}
          x={node.x}
          y={node.y}
          transform={node.transform}
          fontSize={node.size}
          textAnchor={node.anchor}
        >
          {node.content}
        </text>
      );
  }
}

export interface SceneSvgProps {
  scene: ShelfScene;
  /** Read aloud in place of the drawing. Describes the state, not the artwork. */
  label: string;
}

export function SceneSvg({ scene, label }: SceneSvgProps) {
  return (
    <svg className={styles.svg} viewBox={SCENE_VIEWBOX} role="img" aria-label={label}>
      <defs>
        <radialGradient id="shelf-light" cx="34%" cy="24%" r="78%">
          <stop offset="0" className={styles.lightStopIn} />
          <stop offset="1" className={styles.lightStopOut} />
        </radialGradient>
        <radialGradient id="shelf-shadow-contact" cx="50%" cy="50%" r="50%">
          <stop offset="0" className={styles.contactStop0} />
          <stop offset="0.55" className={styles.contactStop1} />
          <stop offset="1" className={styles.contactStop2} />
        </radialGradient>
        <radialGradient id="shelf-shadow-cast" cx="50%" cy="50%" r="50%">
          <stop offset="0" className={styles.castStop0} />
          <stop offset="0.6" className={styles.castStop1} />
          <stop offset="1" className={styles.castStop2} />
        </radialGradient>
      </defs>
      <g className={styles.body}>{scene.body.map(renderNode)}</g>
      <g className={styles.annotations}>{scene.annotations.map(renderNode)}</g>
    </svg>
  );
}
