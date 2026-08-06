using System;
using Newtonsoft.Json;
using Oxide.Core.Libraries.Covalence;
using UnityEngine;

namespace Oxide.Plugins
{
    [Info("RustdMap", "rustd.xyz", "1.0.0")]
    [Description("Renders the server map for the rustd.xyz control panel")]
    internal class RustdMap : CovalencePlugin
    {
        // The panel needs exactly one thing from a plugin: a rendered map. Everything
        // else it does uses vanilla Rust or Oxide commands. This deliberately does
        // nothing else — the plugin it replaces broke on a game update in a code path
        // the panel never used, and took the map down with it.
        [Command("rustd.rendermap")]
        private void CommandRenderMap(IPlayer player, string command, string[] args)
        {
            // Console only. Rendering is expensive, so a player-triggerable render is a
            // denial-of-service handle.
            if (!player.IsServer)
            {
                return;
            }

            const float defaultRes = 3000f;

            float scale;
            if (args.Length == 0 || !float.TryParse(args[0], out scale))
            {
                scale = (defaultRes - 1000f) / World.Size;
            }

            scale = Mathf.Clamp(scale, 0.1f, 4f);

            try
            {
                int height, width;
                Color background;
                var imageData = Convert.ToBase64String(
                    MapImageRenderer.Render(out width, out height, out background, scale, false));

                player.Reply(JsonConvert.SerializeObject(new
                {
                    Height = height,
                    Width = width,
                    Base64 = imageData
                }));
            }
            catch (Exception ex)
            {
                // Reply with something that cannot be mistaken for a render: the parser
                // requires a JSON object containing "Height", so this falls through to
                // "no map this time" and the panel keeps serving its cached map.
                LogError("rustd.rendermap failed: " + ex);
                player.Reply("rustd.rendermap failed");
            }
        }
    }
}
