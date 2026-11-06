import { describe, it, expect, vi, beforeEach } from "vitest";
import { vitestWaitFor } from "../helpers/wait_for.js";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";

vi.mock("axios", () => import("../mocks/axios.js"));
vi.mock("js-cookie", () => import("../mocks/js_cookie.js"));
import { cookies } from "../mocks/js_cookie.js";

import axios from "axios";
import toastStore from "../../../app/frontend/src/stores/toast_store.js";
import { messagesShown } from "../helpers/form_messages.js";
import ProfileEdit, {
  formValues,
} from "../../../app/frontend/src/components/profile/edit.tsx";

// What GET /api/v1/profile sends (Api::V1::ProfilesController#show).
const PROFILE = {
  id: 7,
  name: "Jane Smith",
  username: "Jane",
  email: "jane@example.com",
  pending_email: null,
  vegetarian: false,
  children: [{ id: 9, name: "Kid Smith", vegetarian: false }],
};

function renderForm({ handleCloseModal = vi.fn(), setDirty = vi.fn() } = {}) {
  render(
    <ProfileEdit
      handleCloseModal={handleCloseModal}
      setDirty={setDirty}
      setErrorShown={vi.fn()}
    />,
  );
  return { handleCloseModal, setDirty };
}

function deferred() {
  const d = {};
  d.promise = new Promise(function (resolve, reject) {
    d.resolve = resolve;
    d.reject = reject;
  });
  return d;
}

async function loaded() {
  await screen.findByDisplayValue("Jane Smith");
}

describe("formValues", () => {
  it("shows the address that waits for its link in the email box", () => {
    expect(
      formValues({ ...PROFILE, pending_email: "new@example.com" }).email,
    ).toBe("new@example.com");
  });

  // An admin can clear the email of a resident who is signed in.
  it("shows an empty email box when the resident has no email", () => {
    expect(formValues({ ...PROFILE, email: null }).email).toBe("");
  });

  it("shows the email when no change waits", () => {
    expect(formValues(PROFILE).email).toBe("jane@example.com");
  });
});

describe("ProfileEdit", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    toastStore.clearAll();
    axios.get.mockResolvedValue({ status: 200, data: PROFILE });
  });

  it("loads the profile and the children into the form", async () => {
    renderForm();

    expect(screen.getByText("Loading...")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Save" })).toBeNull();
    await loaded();
    expect(axios.get).toHaveBeenCalledWith("/api/v1/profile");
    expect(screen.getByLabelText("Email")).toHaveValue("jane@example.com");
    expect(
      screen.getByLabelText("Vegetarian", { selector: "#profile-vegetarian" }),
    ).not.toBeChecked();
    expect(
      screen.getByRole("heading", { name: "Child: Kid Smith" }),
    ).toBeVisible();
    expect(
      screen.getByLabelText("Name", { selector: "#profile-child-9-name" }),
    ).toHaveValue("Kid Smith");
    expect(screen.getByRole("button", { name: "Save" })).toBeEnabled();
    expect(screen.queryByText(/Not changed yet/)).toBeNull();
  });

  it("shows why the form stays empty when the profile does not load", async () => {
    axios.get.mockRejectedValue({
      response: {
        status: 403,
        data: { message: "Only a resident may do this." },
      },
    });
    renderForm();

    await vitestWaitFor(() =>
      expect(messagesShown().form).toEqual(["Only a resident may do this."]),
    );
    expect(screen.queryByRole("button", { name: "Save" })).toBeNull();
  });

  it("reports changes as unsaved, and none once they are typed back", async () => {
    const { setDirty } = renderForm();
    await loaded();

    fireEvent.change(
      screen.getByLabelText("Name", { selector: "#profile-name" }),
      {
        target: { value: "Jane Q Smith" },
      },
    );
    expect(setDirty).toHaveBeenLastCalledWith(true);

    fireEvent.change(
      screen.getByLabelText("Name", { selector: "#profile-name" }),
      {
        target: { value: "Jane Smith" },
      },
    );
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });

  it("saves every field, keeps the new short name, says so, and closes", async () => {
    const saved = {
      ...PROFILE,
      name: "Janet Smith",
      username: "Janet",
      vegetarian: true,
    };
    axios.patch.mockResolvedValue({
      status: 200,
      data: { message: "Your profile has been saved.", profile: saved },
    });
    const { handleCloseModal, setDirty } = renderForm();
    await loaded();

    fireEvent.change(
      screen.getByLabelText("Name", { selector: "#profile-name" }),
      {
        target: { value: "Janet Smith" },
      },
    );
    fireEvent.click(
      screen.getByLabelText("Vegetarian", { selector: "#profile-vegetarian" }),
    );
    fireEvent.change(screen.getByLabelText("Email"), {
      target: { value: "janet@example.com" },
    });
    fireEvent.change(
      screen.getByLabelText("Name", { selector: "#profile-child-9-name" }),
      {
        target: { value: "Kit Smith" },
      },
    );
    fireEvent.click(
      screen.getByLabelText("Vegetarian", {
        selector: "#profile-child-9-vegetarian",
      }),
    );
    // The heading keeps the name the child had when the form loaded.
    expect(
      screen.getByRole("heading", { name: "Child: Kid Smith" }),
    ).toBeVisible();
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    expect(screen.getByRole("button", { name: "Save" })).toHaveClass(
      "button-loader",
    );
    await vitestWaitFor(() => expect(handleCloseModal).toHaveBeenCalled());
    expect(axios.patch).toHaveBeenCalledWith("/api/v1/profile", {
      name: "Janet Smith",
      email: "janet@example.com",
      vegetarian: true,
      children: [{ id: 9, name: "Kit Smith", vegetarian: true }],
    });
    expect(cookies.current.username).toBe("Janet");
    expect(messagesShown().stack).toEqual(["Your profile has been saved."]);
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });

  it("changes only the child whose box was typed in", async () => {
    axios.get.mockResolvedValue({
      status: 200,
      data: {
        ...PROFILE,
        children: [
          ...PROFILE.children,
          { id: 10, name: "Ivy Smith", vegetarian: true },
        ],
      },
    });
    axios.patch.mockResolvedValue({
      status: 200,
      data: { message: "Your profile has been saved.", profile: PROFILE },
    });
    renderForm();
    await loaded();

    fireEvent.change(
      screen.getByLabelText("Name", { selector: "#profile-child-10-name" }),
      {
        target: { value: "Ivy Rose Smith" },
      },
    );
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    await vitestWaitFor(() => expect(axios.patch).toHaveBeenCalled());
    expect(axios.patch.mock.calls[0][1].children).toEqual([
      { id: 9, name: "Kid Smith", vegetarian: false },
      { id: 10, name: "Ivy Rose Smith", vegetarian: true },
    ]);
  });

  it("shows a refused save inside the form, and stays open", async () => {
    axios.patch.mockRejectedValue({
      response: { status: 400, data: { message: "Email is invalid" } },
    });
    const { handleCloseModal } = renderForm();
    await loaded();

    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    await vitestWaitFor(() =>
      expect(messagesShown().form).toEqual(["Email is invalid"]),
    );
    expect(handleCloseModal).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Save" })).toBeEnabled();
  });

  // 503: saved, but the link to the new address did not go out.
  it("shows what was saved when the link email failed, and says why", async () => {
    const saved = {
      ...PROFILE,
      name: "Janet Smith",
      username: "Janet",
      pending_email: "janet@example.com",
    };
    axios.patch.mockRejectedValue({
      response: {
        status: 503,
        data: { message: "The email could not be sent.", profile: saved },
      },
    });
    const { setDirty } = renderForm();
    await loaded();

    fireEvent.change(
      screen.getByLabelText("Name", { selector: "#profile-name" }),
      {
        target: { value: "Janet Smith" },
      },
    );
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    await vitestWaitFor(() =>
      expect(messagesShown().form).toEqual(["The email could not be sent."]),
    );
    expect(cookies.current.username).toBe("Janet");
    expect(screen.getByLabelText("Email")).toHaveValue("janet@example.com");
    expect(screen.getByText(/Not changed yet/)).toBeVisible();
    expect(setDirty).toHaveBeenLastCalledWith(false);
  });

  describe("an email change that waits for its link", () => {
    beforeEach(() => {
      axios.get.mockResolvedValue({
        status: 200,
        data: { ...PROFILE, pending_email: "new@example.com" },
      });
    });

    it("says the email has not changed yet, and which one signs in", async () => {
      renderForm();

      await screen.findByDisplayValue("new@example.com");
      expect(
        screen.getByText(
          "Not changed yet. Open the link we sent to new@example.com. Until then, sign in with jane@example.com.",
          { exact: false },
        ),
      ).toBeVisible();
    });

    it("sends the link again", async () => {
      const answer = deferred();
      axios.post.mockReturnValue(answer.promise);
      renderForm();
      await screen.findByDisplayValue("new@example.com");

      fireEvent.click(
        screen.getByRole("button", { name: "Send the link again" }),
      );
      expect(
        screen.getByRole("button", { name: "Send the link again" }),
      ).toBeDisabled();
      answer.resolve({
        status: 200,
        data: { message: "We sent a new link to new@example.com." },
      });

      await vitestWaitFor(() =>
        expect(messagesShown().stack).toEqual([
          "We sent a new link to new@example.com.",
        ]),
      );
      expect(axios.post).toHaveBeenCalledWith("/api/v1/profile/email-link");
      expect(
        screen.getByRole("button", { name: "Send the link again" }),
      ).toBeEnabled();
    });

    it("shows inside the form why the link was not sent", async () => {
      axios.post.mockRejectedValue({
        response: { status: 503, data: { message: "Could not be sent." } },
      });
      renderForm();
      await screen.findByDisplayValue("new@example.com");

      fireEvent.click(
        screen.getByRole("button", { name: "Send the link again" }),
      );

      await vitestWaitFor(() =>
        expect(messagesShown().form).toEqual(["Could not be sent."]),
      );
    });
  });

  describe("an answer that comes after the form closed", () => {
    it("is not shown, for the load", async () => {
      const answer = deferred();
      axios.get.mockReturnValue(answer.promise);
      renderForm();
      cleanup();
      answer.reject({ response: { status: 500, data: { message: "Boom" } } });
      await answer.promise.catch(() => {});
      expect(messagesShown().stack).toEqual([]);
    });

    it("is not shown, for a load that worked", async () => {
      const answer = deferred();
      axios.get.mockReturnValue(answer.promise);
      renderForm();
      cleanup();
      answer.resolve({ status: 200, data: PROFILE });
      await answer.promise;
    });

    it("is not shown, for a save", async () => {
      const save = deferred();
      axios.patch.mockReturnValue(save.promise);
      const { handleCloseModal } = renderForm();
      await loaded();
      fireEvent.click(screen.getByRole("button", { name: "Save" }));
      cleanup();
      save.resolve({
        status: 200,
        data: { message: "Saved", profile: PROFILE },
      });
      await save.promise;
      expect(handleCloseModal).not.toHaveBeenCalled();
    });

    it("is not shown, for a refused save", async () => {
      const save = deferred();
      axios.patch.mockReturnValue(save.promise);
      renderForm();
      await loaded();
      fireEvent.click(screen.getByRole("button", { name: "Save" }));
      cleanup();
      save.reject({ response: { status: 400, data: { message: "No" } } });
      await save.promise.catch(() => {});
      expect(messagesShown().stack).toEqual([]);
    });

    it("is not shown, for the link sent again", async () => {
      axios.get.mockResolvedValue({
        status: 200,
        data: { ...PROFILE, pending_email: "new@example.com" },
      });
      const sent = deferred();
      axios.post.mockReturnValue(sent.promise);
      renderForm();
      await screen.findByDisplayValue("new@example.com");
      fireEvent.click(
        screen.getByRole("button", { name: "Send the link again" }),
      );
      cleanup();
      sent.resolve({ status: 200, data: { message: "Sent" } });
      await sent.promise;
      expect(messagesShown().stack).toEqual([]);
    });

    it("is not shown, for a link that was not sent again", async () => {
      axios.get.mockResolvedValue({
        status: 200,
        data: { ...PROFILE, pending_email: "new@example.com" },
      });
      const sent = deferred();
      axios.post.mockReturnValue(sent.promise);
      renderForm();
      await screen.findByDisplayValue("new@example.com");
      fireEvent.click(
        screen.getByRole("button", { name: "Send the link again" }),
      );
      cleanup();
      sent.reject({ response: { status: 503, data: { message: "No" } } });
      await sent.promise.catch(() => {});
      expect(messagesShown().stack).toEqual([]);
    });
  });
});
