export type AdministratorAccountKind = 'signed-out' | 'google' | 'unavailable';

export interface AdministratorAccount {
  readonly kind: AdministratorAccountKind;
  readonly userId: string;
  readonly displayName: string;
  readonly email: string;
  readonly notice: string;
  signInWithGoogle(): Promise<void>;
  signOut(): Promise<void>;
}
