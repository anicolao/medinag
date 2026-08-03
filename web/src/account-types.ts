export type AdvisorAccountKind =
  | 'preview'
  | 'anonymous'
  | 'google'
  | 'migration-error';

export interface AdvisorAccount {
  readonly kind: AdvisorAccountKind;
  readonly displayName: string;
  readonly email: string;
  readonly notice: string;
  linkGoogle(): Promise<void>;
}
