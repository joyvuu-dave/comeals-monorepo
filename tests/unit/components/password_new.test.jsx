import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  act,
} from "@testing-library/react";
import { MemoryRouter, Routes, Route, useLocation } from "react-router";

vi.mock("axios", () => import("../mocks/axios.js"));

import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { messagesShown } from "../helpers/form_messages.js";
import ResidentsPasswordNew, {
  NO_TOKEN,
  RETIRED_LINK,
  tokenFromHash,
} from "../../../app/frontend/src/components/residents/password_new.jsx";

function LocationEcho() {
  const location = useLocation();
  return (
    <span data-testid="location">
      {location.pathname + location.search + location.hash}
    </span>
  );
}

// The page reads the reset token from the part of the address after
// the #, as the reset email writes it.
function renderForm(address = "/reset-password#token=tok-1") {
  render(
    <MemoryRouter initialEntries={[address]}>
      <Routes>
        <Route path="/:modal/:token?/*" element={<ResidentsPasswordNew />} />
        <Route path="/" element={<span>login page</span>} />
      </Routes>
      <LocationEcho />
    </MemoryRouter>,
  );
}

function deferred() {
  const d = {};
  d.promise = new Promise(function (resolve, reject) {
    d.resolve = resolve;
    d.reject = reject;
  });
  return d;
}

const NAME_URL = "/api/v1/residents/password-reset/name";
const SAVE_URL = "/api/v1/residents/password-reset/new";

describe("tokenFromHash", () => {
  it("reads the token after #token=", () => {
    expect(tokenFromHash("#token=abc-_123")).toBe("abc-_123");
  });

  it("is empty when there is no token", () => {
    expect(tokenFromHash("")).toBe("");
    expect(tokenFromHash("#")).toBe("");
    expect(tokenFromHash("#other=1")).toBe("");
  });
});

describe("ResidentsPasswordNew", () => {
  // Both requests are POSTs, so the token is in the body, never in the
  // address: first the name, then the password. Each test sets what the
  // two answer.
  let nameAnswer;
  let saveAnswer;

  beforeEach(() => {
    vi.clearAllMocks();
    toastStore.clearAll();
    nameAnswer = () =>
      Promise.resolve({ status: 200, data: { name: "Jane Smith" } });
    saveAnswer = () => Promise.resolve({ status: 200, data: {} });
    axios.post.mockImplementation((url) =>
      url === NAME_URL ? nameAnswer() : saveAnswer(),
    );
  });

  it("shows Loading until the name arrives, then the form", async () => {
    renderForm();

    expect(screen.getByText("Loading...")).toBeInTheDocument();
    expect(
      await screen.findByText("Reset Password for Jane Smith"),
    ).toBeInTheDocument();
    expect(axios.post).toHaveBeenCalledWith(NAME_URL, { reset_token: "tok-1" });
  });

  // The page keeps the token, so a shared screen and the browser's
  // history do not.
  it("takes the token out of the address once it has read it", async () => {
    renderForm();

    await screen.findByText("Reset Password for Jane Smith");
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/reset-password$/,
    );
  });

  it("submits the typed password with the token", async () => {
    renderForm();

    const input = await screen.findByPlaceholderText("New Password");
    fireEvent.change(input, { target: { value: "hunter2hunter2" } });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    expect(axios.post).toHaveBeenLastCalledWith(SAVE_URL, {
      reset_token: "tok-1",
      password: "hunter2hunter2",
    });
  });

  // A link mailed before 2026-10-23 has the token in the path. Those
  // tokens were all cleared, so the page asks nothing and says to ask for
  // a new link. The token in the path goes to no server request either.
  it("a link of the old kind goes to the login page and says to ask for a new one", async () => {
    renderForm("/reset-password/tok-1/");

    expect(await screen.findByText("login page")).toBeInTheDocument();
    expect(
      toastStore.toasts.map((t) => ({ message: t.message, type: t.type })),
    ).toEqual([{ message: RETIRED_LINK, type: "error" }]);
    expect(axios.post).not.toHaveBeenCalled();
  });

  // The page was reloaded after it took the token out of the address,
  // or the link was cut short.
  it("no token goes to the login page and says to open the link again", async () => {
    renderForm("/reset-password");

    expect(await screen.findByText("login page")).toBeInTheDocument();
    expect(
      toastStore.toasts.map((t) => ({ message: t.message, type: t.type })),
    ).toEqual([{ message: NO_TOKEN, type: "error" }]);
    expect(axios.post).not.toHaveBeenCalled();
  });

  it("a saved password shows the answer and returns to the login page", async () => {
    saveAnswer = () =>
      Promise.resolve({ status: 200, data: { message: "Password updated!" } });
    renderForm();

    const input = await screen.findByPlaceholderText("New Password");
    fireEvent.change(input, { target: { value: "hunter2hunter2" } });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    expect(await screen.findByText("login page")).toBeInTheDocument();
    expect(toastStore.toasts.map((t) => t.message)).toEqual([
      "Password updated!",
    ]);
  });

  // The form is in a dialog, and the stack of messages is drawn under
  // an open dialog, so the reason shows inside the form, under its
  // title (#137).
  it("a refused password shows the reason inside the form and frees the form", async () => {
    // What ResidentsController#password_new answers when the resident
    // row itself no longer saves (#105): one line per field, then who
    // can fix it.
    const reason =
      "Your password was not changed:\nName can't be blank\nPlease ask an admin to fix your account.";
    saveAnswer = () =>
      Promise.reject({ response: { status: 400, data: { message: reason } } });
    renderForm();

    const input = await screen.findByPlaceholderText("New Password");
    fireEvent.change(input, { target: { value: "x" } });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    await vi.waitFor(() => {
      expect(messagesShown()).toEqual({ form: [reason], stack: [] });
    });
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Your password was not changed:",
    );
    expect(screen.getByRole("button", { name: "Submit" })).toBeEnabled();
  });

  // A try that works closes the dialog, and the reasons earlier tries
  // got go with it.
  it("a password saved after a refusal takes the refusal away with the form", async () => {
    const saves = [
      () => Promise.reject({ request: {} }),
      () =>
        Promise.resolve({
          status: 200,
          data: { message: "Password updated!" },
        }),
    ];
    saveAnswer = () => saves.shift()();
    renderForm();
    const input = await screen.findByPlaceholderText("New Password");
    fireEvent.change(input, { target: { value: "hunter2hunter2" } });
    fireEvent.click(screen.getByRole("button", { name: "Submit" }));
    await vi.waitFor(() => {
      expect(messagesShown().form).toEqual([
        "Error: no response received from server.",
      ]);
    });

    fireEvent.click(screen.getByRole("button", { name: "Submit" }));

    expect(await screen.findByText("login page")).toBeInTheDocument();
    expect(messagesShown()).toEqual({
      form: [],
      stack: ["Password updated!"],
    });
  });

  // The two answers the server gives for a link it will not use
  // (ResidentsController#show_name). The person lands on the login
  // page and is told why there.
  it.each([
    "Password reset link is incorrect or expired.",
    "Password reset link has expired. Please request a new one.",
  ])(
    "a link the server refuses goes to the login page and says: %s",
    async (message) => {
      nameAnswer = () =>
        Promise.reject({
          response: { status: 400, data: { message: message } },
        });
      renderForm();
      expect(await screen.findByText("login page")).toBeInTheDocument();
      expect(
        toastStore.toasts.map((t) => ({ message: t.message, type: t.type })),
      ).toEqual([{ message: message, type: "error" }]);
    },
  );

  // Only a 400 says the link is bad. Any other answer says nothing about
  // the link, so the page that can still use it stays, and shows the
  // server's words in place of "Loading...". Reloading the page asks for
  // the name again.
  it.each([
    [
      "Rails' own 500 page",
      { status: 500, data: "<html>500</html>" },
      "The server had a problem. Please try again.",
    ],
    [
      "a Heroku router error",
      { status: 503, data: "<html>Application Error</html>" },
      "The server had a problem. Please try again.",
    ],
    [
      "a conflict ApiController rescued",
      {
        status: 409,
        data: { message: "Someone else saved at the same time." },
      },
      "Someone else saved at the same time.",
    ],
    [
      "too many requests",
      {
        status: 429,
        data: {
          message:
            "Too many requests. Please wait 30 seconds before trying again.",
        },
      },
      "Too many requests. Please wait 30 seconds before trying again.",
    ],
  ])(
    "%s on the name lookup stays on the page and shows why",
    async (_name, response, words) => {
      nameAnswer = () => Promise.reject({ response });
      renderForm();
      expect(await screen.findByText(words)).toBeVisible();
      expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
      expect(
        screen.queryByPlaceholderText("New Password"),
      ).not.toBeInTheDocument();
      expect(screen.getByTestId("location")).toHaveTextContent(
        /^\/reset-password$/,
      );
      expect(toastStore.toasts).toHaveLength(0);
    },
  );

  // With no answer from the server there is nothing to go on, so the
  // page stays and says so, instead of "Loading..." forever.
  it.each([
    // What axios rejects with when no answer came back.
    ["a network failure", { request: {}, message: "Network Error" }],
    // A throw before any request was sent.
    ["an error before the request", new Error("boom")],
  ])("%s on the name lookup says so and stays", async (_name, error) => {
    nameAnswer = () => Promise.reject(error);
    renderForm();
    expect(
      await screen.findByText(
        "Could not load this page. Check your connection and try again.",
      ),
    ).toBeVisible();
    expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
    expect(
      screen.queryByPlaceholderText("New Password"),
    ).not.toBeInTheDocument();
    expect(screen.getByTestId("location")).toHaveTextContent(
      /^\/reset-password$/,
    );
    expect(toastStore.toasts).toHaveLength(0);
  });

  // React shows no sign when it drops a state update on a page that is
  // gone, so this only checks that a late name does not throw.
  it("a name that arrives after the page is gone throws nothing", async () => {
    const name = deferred();
    nameAnswer = () => name.promise;
    renderForm();
    cleanup();
    await act(async () => name.resolve({ status: 200, data: { name: "J" } }));
    expect(document.body).not.toHaveTextContent("Reset Password");
  });

  it("a refusal that arrives after the page is gone shows nothing", async () => {
    const refusedName = deferred();
    nameAnswer = () => refusedName.promise;
    renderForm();
    cleanup();
    await act(async () =>
      refusedName.reject({
        response: {
          status: 400,
          data: { message: "Password reset link is incorrect or expired." },
        },
      }),
    );
    expect(toastStore.toasts).toHaveLength(0);
  });

  it("a save answered after the page is gone shows nothing", async () => {
    for (const settle of ["resolve", "reject"]) {
      const save = deferred();
      saveAnswer = () => save.promise;
      renderForm();
      const input = await screen.findByPlaceholderText("New Password");
      fireEvent.change(input, { target: { value: "hunter2hunter2" } });
      fireEvent.click(screen.getByRole("button", { name: "Submit" }));
      cleanup();
      await act(async () =>
        save[settle]({ status: 200, data: { message: "Late." } }),
      );
    }
    expect(toastStore.toasts).toHaveLength(0);
  });
});
