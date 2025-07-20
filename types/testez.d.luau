type Expectation = {
	to: Expectation;
	be: Expectation;

	been: Expectation;


	 have: Expectation;


	 was: Expectation;


	 at: Expectation;

	 never: Expectation;

	a: (typeName: string) -> Expectation;

	an: (typeName: string) -> Expectation;


	ok: () -> Expectation;


	equal: (otherValue: any) -> Expectation;


	near: (otherValue: any, limit: number?) -> Expectation;

	throw: () -> Expectation;
}

declare function describe(phrase: string, callback: (context: any) -> ())
declare function it(phrase: string, callback: (context: any) -> ())
declare function expect(value: unknown): Expectation
declare function afterAll(callback: (context: any) -> ())
declare function afterEach(callback: (context: any) -> ())
declare function beforeAll(callback: (context: any) -> ())
declare function beforeEach(callback: (context: any) -> ())
declare function FIXME(optionalMessage: string?)
declare function FOCUS()
declare function SKIP()
declare function describeFOCUS(phrase: string, callback: (context: {}) -> ())
declare function describeSKIP(phrase: string, callback: (context: {}) -> ())
declare function itFOCUS(phrase: string, callback: (context: {}) -> ())
declare function itSKIP(phrase: string, callback: (context: {}) -> ())
declare function itFIXME(phrase: string, callback: (context: {}) -> ())