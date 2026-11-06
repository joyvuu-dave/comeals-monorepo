import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import axios from "axios";
import Cookie from "js-cookie";
import useFormMessages from "../../helpers/use_form_messages";
import useDirtyReport from "../../helpers/use_dirty_report";
import useMountedRef from "../../helpers/use_mounted_ref";
import toastStore from "../../stores/toast_store";
import ModalFormHeader from "../modal_form/header";
import FormMessages from "../modal_form/form_messages";

// A child the resident may edit: one in their unit with no email.
interface Child {
  id: number;
  name: string;
  vegetarian: boolean;
}

// What GET /api/v1/profile sends (ProfileUpdate.profile on the server).
export interface Profile {
  id: number;
  name: string;
  // The short name the headers show.
  username: string;
  email: string | null;
  // An address that waits for its link, or null.
  pending_email: string | null;
  vegetarian: boolean;
  children: Child[];
}

// What the form holds, and sends as PATCH /api/v1/profile.
interface Values {
  name: string;
  email: string;
  vegetarian: boolean;
  children: Child[];
}

interface Props {
  handleCloseModal: () => void;
  setDirty: (dirty: boolean) => void;
  setErrorShown: (shown: boolean) => void;
}

// The form's values from a profile the server sent. The email box shows
// the address the person asked for when one waits for its link: saving
// it again leaves the change waiting (ProfileUpdate on the server), and
// typing the old address back takes the change off.
export function formValues(profile: Profile): Values {
  return {
    name: profile.name,
    email: profile.pending_email || profile.email || "",
    vegetarian: profile.vegetarian,
    children: profile.children.map(function (child) {
      return { id: child.id, name: child.name, vegetarian: child.vegetarian };
    }),
  };
}

// The profile a failed save still sent: a 503 saved the profile, but
// the link to a new email did not go out (ProfilesController#render_saved).
function savedProfileIn(error: unknown): Profile | null {
  const response = (error as { response?: { data?: { profile?: Profile } } })
    .response;
  return response?.data?.profile ?? null;
}

// The header shows the short name from the sign-in's cookie
// (login.jsx). A save that changed the name hands back the new one.
function keepUsername(profile: Profile) {
  Cookie.set("username", profile.username, { expires: 7300 });
}

// The signed-in resident's own profile (ADR 0014): their name, email and
// vegetarian setting, and the same for each child in their unit who has
// no email. A draft with a Save button, like every calendar form (ADR
// 0006). The Common House screen has no profile, and the calendar shows
// it no link here.
function ProfileEdit({ handleCloseModal, setDirty, setErrorShown }: Props) {
  const [profile, setProfile] = useState<Profile | null>(null);
  const [values, setValues] = useState<Values | null>(null);
  const [saving, setSaving] = useState(false);
  const [sending, setSending] = useState(false);

  const mountedRef = useMountedRef();
  const formMessages = useFormMessages(setErrorShown);
  const showError = formMessages.showError;

  // The values the form started from, for the dirty check, and the
  // children's names for their headings, which do not change while a
  // name box is typed in.
  const initialRef = useRef<Values | null>(null);

  function take(newProfile: Profile) {
    const initial = formValues(newProfile);
    initialRef.current = initial;
    setProfile(newProfile);
    setValues(initial);
  }

  useEffect(
    function () {
      axios
        .get<Profile>("/api/v1/profile")
        .then(function (response) {
          if (!mountedRef.current) return;
          take(response.data);
        })
        .catch(function (error: unknown) {
          if (!mountedRef.current) return;
          showError(error);
        });
    },
    [mountedRef, showError],
  );

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    axios
      .patch<{ message: string; profile: Profile }>("/api/v1/profile", values)
      .then(function (response) {
        if (!mountedRef.current) return;
        setSaving(false);
        keepUsername(response.data.profile);
        toastStore.show(response.data.message, "success");
        // Saved: close without the discard question (ADR 0006).
        setDirty(false);
        handleCloseModal();
      })
      .catch(function (error: unknown) {
        if (!mountedRef.current) return;
        setSaving(false);
        const saved = savedProfileIn(error);
        if (saved) {
          keepUsername(saved);
          take(saved);
        }
        showError(error);
      });
  }

  function handleSendAgain() {
    setSending(true);
    axios
      .post<{ message: string }>("/api/v1/profile/email-link")
      .then(function (response) {
        if (!mountedRef.current) return;
        setSending(false);
        toastStore.show(response.data.message, "success");
      })
      .catch(function (error: unknown) {
        if (!mountedRef.current) return;
        setSending(false);
        showError(error);
      });
  }

  function change(changes: Partial<Values>) {
    setValues((current) => current && { ...current, ...changes });
  }

  function changeChild(id: number, changes: Partial<Child>) {
    setValues(
      (current) =>
        current && {
          ...current,
          children: current.children.map((child) =>
            child.id === id ? { ...child, ...changes } : child,
          ),
        },
    );
  }

  useDirtyReport(
    setDirty,
    values !== null &&
      JSON.stringify(values) !== JSON.stringify(initialRef.current),
  );

  function loadedName(id: number): string {
    return initialRef.current!.children.find((child) => child.id === id)!.name;
  }

  return (
    <div>
      <ModalFormHeader title="Your Profile" onClose={handleCloseModal} />
      <FormMessages
        messages={formMessages.messages}
        close={formMessages.close}
      />
      {values === null ? (
        <p>Loading...</p>
      ) : (
        <fieldset data-populated="true">
          <form onSubmit={handleSubmit}>
            <label htmlFor="profile-name">Name</label>
            <input
              id="profile-name"
              type="text"
              value={values.name}
              onChange={(e) => change({ name: e.target.value })}
              disabled={saving}
            />
            <br />
            <label htmlFor="profile-email">Email</label>
            <input
              id="profile-email"
              type="email"
              autoCapitalize="none"
              value={values.email}
              onChange={(e) => change({ email: e.target.value })}
              disabled={saving}
            />
            {profile!.pending_email !== null && (
              <p className="profile-pending">
                {`Not changed yet. Open the link we sent to ${profile!.pending_email}. ` +
                  `Until then, sign in with ${profile!.email}.`}{" "}
                <button
                  type="button"
                  className="button-link"
                  onClick={handleSendAgain}
                  disabled={sending || saving}
                >
                  Send the link again
                </button>
              </p>
            )}
            <br />
            <label htmlFor="profile-vegetarian">Vegetarian</label>
            {"  "}
            <input
              id="profile-vegetarian"
              type="checkbox"
              checked={values.vegetarian}
              onChange={(e) => change({ vegetarian: e.target.checked })}
              disabled={saving}
            />
            {values.children.map((child) => (
              <div key={child.id} className="profile-child">
                <br />
                <h3>{`Child: ${loadedName(child.id)}`}</h3>
                <label htmlFor={`profile-child-${child.id}-name`}>Name</label>
                <input
                  id={`profile-child-${child.id}-name`}
                  type="text"
                  value={child.name}
                  onChange={(e) =>
                    changeChild(child.id, { name: e.target.value })
                  }
                  disabled={saving}
                />
                <br />
                <label htmlFor={`profile-child-${child.id}-vegetarian`}>
                  Vegetarian
                </label>
                {"  "}
                <input
                  id={`profile-child-${child.id}-vegetarian`}
                  type="checkbox"
                  checked={child.vegetarian}
                  onChange={(e) =>
                    changeChild(child.id, { vegetarian: e.target.checked })
                  }
                  disabled={saving}
                />
              </div>
            ))}
            <br />
            <br />
            <button
              type="submit"
              className={saving ? "button-dark button-loader" : "button-dark"}
              disabled={saving}
            >
              Save
            </button>
          </form>
        </fieldset>
      )}
    </div>
  );
}

export default ProfileEdit;
