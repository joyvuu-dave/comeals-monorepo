// js-cookie ships no types. These are the three functions the app
// calls, with the options it passes.
declare module "js-cookie" {
  interface CookieAttributes {
    expires?: number | Date;
    path?: string;
  }

  const Cookie: {
    get(name: string): string | undefined;
    set(
      name: string,
      value: string | number,
      attributes?: CookieAttributes,
    ): void;
    remove(name: string, attributes?: CookieAttributes): void;
  };

  export default Cookie;
}
