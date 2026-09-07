import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError, type Abi } from "viem";

/**
 * What a rejected transaction actually said.
 *
 * Every contract in this deployment reverts with a typed error carrying its arguments -- the asset,
 * the balance, the requested amount, the borrowing power it would have blown. A wallet shows the
 * user a selector; this turns the same bytes back into the sentence the contract was written to
 * say, so a refused action is explained by the protocol rather than paraphrased by the interface.
 */
export interface DecodedRevert {
  /** The Solidity error name, e.g. `Undercollateralized`. */
  name: string;
  /** Its arguments in declaration order, already stringified. */
  args: { key: string; value: string }[];
}

/** Pulls the typed error out of a thrown viem write/simulate error, when there is one. */
export function decodeRevert(error: unknown, abi: Abi): DecodedRevert | null {
  if (!(error instanceof BaseError)) return null;
  const reverted = error.walk((candidate) => candidate instanceof ContractFunctionRevertedError);
  if (!(reverted instanceof ContractFunctionRevertedError)) return null;

  const data = reverted.data;
  if (data === undefined) {
    const reason = reverted.reason;
    return reason === undefined ? null : { name: "Error", args: [{ key: "reason", value: reason }] };
  }

  const definition = abi.find(
    (entry): entry is Extract<Abi[number], { type: "error" }> =>
      entry.type === "error" && entry.name === data.errorName,
  );
  const names = definition?.inputs.map((input, index) => input.name ?? `arg${index}`) ?? [];

  return {
    name: data.errorName,
    args: (data.args ?? []).map((value, index) => ({
      key: names[index] ?? `arg${index}`,
      value: formatArgument(value),
    })),
  };
}

function formatArgument(value: unknown): string {
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") return String(value);
  return JSON.stringify(value);
}

/** True when the person closed their wallet rather than the chain refusing the call. */
export function isUserRejection(error: unknown): boolean {
  if (!(error instanceof BaseError)) return false;
  return error.walk((candidate) => candidate instanceof UserRejectedRequestError) !== null;
}

/** One line a reader can act on, for the failures that carry no typed error. */
export function errorMessage(error: unknown): string {
  if (isUserRejection(error)) return "You closed the request in your wallet. Nothing was sent.";
  if (error instanceof BaseError) return error.shortMessage;
  if (error instanceof Error) return error.message.split("\n")[0] ?? "The transaction did not go through.";
  return "The transaction did not go through.";
}
