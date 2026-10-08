import toastStore from "../stores/toast_store";

// What a person sees when the server answered with an error but sent no
// message we can show. Only the errors ApiController rescues carry a
// message (api_controller.rb). Any other exception gets Rails' own page
// (public/500.html), and a Heroku router error gets Heroku's page, so
// response.data is HTML or has no `message`.
var SERVER_PROBLEM = "The server had a problem. Please try again.";

// Show a failed request to the person as a toast, in place of any toast
// on screen, or only log it when `options.silent` is true. Returns the
// id of the toast it showed, or null when it showed none. A caller keeps
// the id to tell later whether that toast is still on screen.
export default function handleAxiosError(error, options) {
  var silent = options && options.silent;
  if (error.response) {
    var data = error.response.data;
    if (data && data.message) {
      if (silent) {
        console.error(data.message);
        return null;
      }
      var toastType = data.type === "warning" ? "warning" : "error";
      return toastStore.replaceAll(data.message, toastType);
    } else {
      console.error("Bad response from server", error);
      if (silent) return null;
      return toastStore.replaceAll(SERVER_PROBLEM, "error");
    }
  } else if (error.request) {
    if (silent) {
      console.error("Error: no response received from server.");
      return null;
    }
    return toastStore.replaceAll(
      "Error: no response received from server.",
      "error",
    );
  } else {
    if (silent) {
      console.error("Error: could not submit form.");
      return null;
    }
    return toastStore.replaceAll("Error: could not submit form.", "error");
  }
}
