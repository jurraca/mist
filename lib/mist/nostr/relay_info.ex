defmodule Mist.Nostr.RelayInfo do


   def get("wss" <> rest), do: get("https" <> rest)

   def get("ws" <> rest), do: get("http" <> rest)

   def get(url) do
     header = %{"accept" => "application/nostr+json"}
     case Req.get(url, headers: header) do
       {:ok, resp} -> {:ok, resp.body}
       err -> err
     end
   end
end
