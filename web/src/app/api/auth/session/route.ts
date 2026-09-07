import { NextResponse } from "next/server";

import { displayName } from "@/server/identity";
import { endSession, readSession } from "@/server/session";

export const dynamic = "force-dynamic";

/** The signed-in account, resolved to a Base name where one exists. */
export async function GET() {
  const session = await readSession();
  if (!session) return NextResponse.json({ signedIn: false });
  return NextResponse.json({
    signedIn: true,
    address: session.address,
    name: await displayName(session.address),
  });
}

export async function DELETE() {
  await endSession();
  return NextResponse.json({ signedIn: false });
}
