import toastStore from "../stores/toast_store";

// What a person sees when the server answered with an error but sent no
// message we can show. Only the errors ApiController rescues carry a
// message (api_controller.rb). Any other exception gets Rails' own page
// (public/500.html), and a Heroku router error gets Heroku's page, so
// response.data is HTML or has no `message`.
var SERVER_PROBLEM = "The server had a problem. Please try again.";

// What a person sees when the answer is Heroku's maintenance page: a 503
// whose HTML says "Offline for maintenance". It shows during a deploy.
// The old code says the same sentence, so a person sees one sentence
// before and after the deploy.
var BEING_UPDATED = "Comeals is being updated. Please try again in a minute.";

function maintenancePage(response) {
  return (
    response.status === 503 &&
    typeof response.data === "string" &&
    /maintenance/i.test(response.data)
  );
}

// Where a message goes when the caller names no other place: the stack
// of messages. Hands back the message's id.
function showInStack(message, type) {
  return toastStore.show(message, type);
}

// Show a failed request to the person, or only log it when
// `options.silent` is true. The message goes on top of the stack of
// messages, and its id is handed back. A calendar form passes
// `options.show`, its own way to show a message inside the form
// (use_form_messages.ts), and the message goes there instead (#137).
// Hands back what `show` hands back, or null when `options.silent` is true.
//
// A 401 means the session has ended. The axios response interceptor
// (data_store_app.js) has already raised the signed-out banner by the
// time the caller's catch runs, so a silent caller logs nothing for it:
// it is not an error in the app (#246). A caller that shows its
// failures still shows it, because there the person tapped something
// and should be told that this tap did nothing.
export default function handleAxiosError(error, options) {
  var silent = options && options.silent;
  var show = (options && options.show) || showInStack;
  if (error.response) {
    if (silent && error.response.status === 401) return null;
    var data = error.response.data;
    if (data && data.message) {
      if (silent) {
        console.error(data.message);
        return null;
      }
      return show(data.message, "error");
    } else {
      console.error("Bad response from server", error);
      if (silent) return null;
      if (maintenancePage(error.response)) {
        return show(BEING_UPDATED, "error");
      }
      return show(SERVER_PROBLEM, "error");
    }
  } else if (error.request) {
    if (silent) {
      console.error("Error: no response received from server.");
      return null;
    }
    return show("Error: no response received from server.", "error");
  } else {
    if (silent) {
      console.error("Error: could not submit form.");
      return null;
    }
    return show("Error: could not submit form.", "error");
  }
}
