#include <SDL2/SDL.h>
#include <stdio.h>

int main(void)
{
    int count;
    int i;

    if (SDL_Init(SDL_INIT_GAMECONTROLLER | SDL_INIT_JOYSTICK) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }

    count = SDL_NumJoysticks();

    printf("SDL joystick count: %d\n", count);

    for (i = 0; i < count; i++) {
        SDL_JoystickGUID guid;
        char guid_string[64];

        guid = SDL_JoystickGetDeviceGUID(i);
        SDL_JoystickGetGUIDString(
            guid,
            guid_string,
            sizeof(guid_string)
        );

        printf("\nJoystick %d\n", i);
        printf("Name: %s\n", SDL_JoystickNameForIndex(i));
        printf("GUID: %s\n", guid_string);
        printf(
            "Recognized as controller: %s\n",
            SDL_IsGameController(i) ? "yes" : "no"
        );

        if (SDL_IsGameController(i)) {
            printf(
                "Controller name: %s\n",
                SDL_GameControllerNameForIndex(i)
            );
        }
    }

    SDL_Quit();
    return 0;
}
