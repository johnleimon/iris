-----------------------------------------------------------
--                                                       --
-- IRIS                                                  --
--                                                       --
-- Copyright (c) 2017, John Leimon                       --
--                                                       --
-- Permission to use, copy, modify, and/or distribute    --
-- this software for any purpose with or without fee is  --
-- hereby granted, provided that the above copyright     --
-- notice and this permission notice appear in all       --
-- copies.                                               --
--                                                       --
-- THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR       --
-- DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE --
-- INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY   --
-- AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE   --
-- FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL   --
-- DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM      --
-- LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION    --
-- OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,     --
-- ARISING OUT OF OR IN CONNECTION WITH THE USE OR       --
-- PERFORMANCE OF THIS SOFTWARE.                         --
-----------------------------------------------------------
WITH ADA.CALENDAR;            USE ADA.CALENDAR;
WITH ADA.COMMAND_LINE;        USE ADA.COMMAND_LINE;
WITH ADA.DIRECTORIES;         USE ADA.DIRECTORIES;
WITH ADA.EXCEPTIONS;          USE ADA.EXCEPTIONS;
WITH ADA.TASK_IDENTIFICATION; USE ADA.TASK_IDENTIFICATION;
WITH ADA.TEXT_IO;             USE ADA.TEXT_IO;
WITH ADA.STRINGS.UNBOUNDED;   USE ADA.STRINGS.UNBOUNDED;
WITH ADA.STRINGS.FIXED;       USE ADA.STRINGS.FIXED;
WITH GNAT.CALENDAR.TIME_IO;
WITH INTERFACES.C;            USE INTERFACES.C;
WITH SIGINT_HANDLER;          USE SIGINT_HANDLER;

PROCEDURE IRIS IS

   PACKAGE FLOAT_TEXT_IO IS NEW ADA.TEXT_IO.FLOAT_IO (FLOAT);

   TYPE IMAGE_ID IS (A, B);

   IMAGE_A_FILENAME    : CONSTANT STRING  := ".IMAGE_A.jpg";
   IMAGE_B_FILENAME    : CONSTANT STRING  := ".IMAGE_B.jpg";
   IPC_FILENAME        : CONSTANT STRING  := ".iris";
   LOG_FILENAME        : CONSTANT 
         GNAT.CALENDAR.TIME_IO.PICTURE_STRING
           := "%Y%m%d-%H%M-%S.%i.jpg";
   TRASH_OUTPUTS       : CONSTANT STRING  := " >&2 2> /dev/null";
   CAPTURE_COUNT       : CONSTANT NATURAL := 10;

   TRIGGER_THRESHOLD   : CONSTANT FLOAT   := 1.0;

   MOTION_DEBUG        : CONSTANT BOOLEAN := TRUE;
   CAPTURE_DEBUG       : CONSTANT BOOLEAN := FALSE;
   IMAGE_COMPARE_DEBUG : CONSTANT BOOLEAN := FALSE;

   NEXT_IMAGE          : IMAGE_ID := A;

   A_CAPTURE_TIME      : TIME;
   B_CAPTURE_TIME      : TIME;

   CAPTURES_REMAINING  : NATURAL := 0;
   DIFF                : STRING  := ".DELTA.jpg";
   DIFF_AMOUNT         : FLOAT   := 0.0;
   PREV_DIFF_AMOUNT    : FLOAT   := 0.0;

   CAMERA_NAME         : UNBOUNDED_STRING :=
                           TO_UNBOUNDED_STRING ("NO NAME");

   LOG_DIRECTORY       : UNBOUNDED_STRING :=
                           TO_UNBOUNDED_STRING (".");
   
   TASK TYPE VIEWER IS
      ENTRY START (IMAGE_FILENAME : IN  STRING;
                   ID             : OUT TASK_ID);
   END VIEWER;

   LIVE_VIEWER    : VIEWER;
   DIFF_VIEWER    : VIEWER;
   LIVE_VIEWER_ID : TASK_ID;
   DIFF_VIEWER_ID : TASK_ID;

   PROCEDURE SYSTEM (ARGUMENTS : CHAR_ARRAY);
   PRAGMA IMPORT (C, SYSTEM, "system");

   -----------------
   -- FILE_EXISTS --
   -----------------

   FUNCTION FILE_EXISTS
      (FILE_NAME : STRING)
       RETURN BOOLEAN
   IS
      THE_FILE : FILE_TYPE;
   BEGIN
      OPEN (THE_FILE, IN_FILE, FILE_NAME);
      CLOSE (THE_FILE);
      RETURN TRUE;
   EXCEPTION
      WHEN ADA.TEXT_IO.NAME_ERROR =>
         RETURN FALSE;
   END FILE_EXISTS;


   ------------ 
   -- VIEWER --
   ------------ 

   TASK BODY VIEWER IS
      ITERATION_COUNT : NATURAL := 0;
      IMAGE           : UNBOUNDED_STRING;
   BEGIN
      ACCEPT START (IMAGE_FILENAME : IN STRING;
                    ID             : OUT TASK_ID)
      DO
         IMAGE := TO_UNBOUNDED_STRING (IMAGE_FILENAME);
         ID    := CURRENT_TASK;
      END START;

      LOOP
         EXIT WHEN FILE_EXISTS (TO_STRING (IMAGE));
         DELAY 0.1;
      END LOOP;

      SYSTEM (TO_C ("feh --reload 0.1 " & TO_STRING (IMAGE) & TRASH_OUTPUTS));
   EXCEPTION
      WHEN ERROR: OTHERS =>
         PUT ("IRIS.VIEWER: ");
         PUT (EXCEPTION_INFORMATION (ERROR));
   END VIEWER;

   -------------
   -- CAPTURE --
   -------------

   PROCEDURE CAPTURE
      (FILE_NAME : STRING)
   IS
      IPC_FILE : FILE_TYPE;
      BEFORE   : TIME;
      AFTER    : TIME;
      COMMAND  : STRING := "fswebcam --subtitle " &
                            """" &
                            TO_STRING (CAMERA_NAME) &
                            """ " &
                            FILE_NAME &
                            TRASH_OUTPUTS;
   BEGIN
      BEFORE := CLOCK;
      SYSTEM (TO_C (COMMAND));
      AFTER  := CLOCK;

      IF CAPTURE_DEBUG THEN
         PUT_LINE (COMMAND);
         PUT_LINE ("Capture completed in" &
                  DURATION'IMAGE (AFTER - BEFORE) &
                  " seconds");
      END IF;
   END CAPTURE;

   -------------
   -- COMPARE --
   -------------

   FUNCTION COMPARE
      RETURN FLOAT
   IS
      BEFORE   : TIME;
      AFTER    : TIME;
      IPC_FILE : FILE_TYPE;
      OUTPUT   : FLOAT;
   BEGIN

      IF NOT FILE_EXISTS (IMAGE_A_FILENAME) OR
         NOT FILE_EXISTS (IMAGE_B_FILENAME)
      THEN
         RETURN 0.0;
      END IF;

      BEFORE := CLOCK;
      DECLARE
         COMMAND : STRING :=
                    "compare -compose Src " &
                    "-fuzz 35% " &
                    "-highlight-color Green " &
                    "-lowlight-color Black " &
                    "-metric MAE " &
                    IMAGE_A_FILENAME & " " &
                    IMAGE_B_FILENAME &
                    " " & DIFF & " 2> " &
                    IPC_FILENAME;
      BEGIN
         IF IMAGE_COMPARE_DEBUG THEN
            PUT_LINE (COMMAND);
         END IF;
         SYSTEM (TO_C (COMMAND));
      END;
      AFTER := CLOCK;

      IF IMAGE_COMPARE_DEBUG THEN
         PUT_LINE ("Compare completed in" & DURATION'IMAGE(AFTER - BEFORE) &
                   " seconds");
      END IF;

      OPEN (IPC_FILE, IN_FILE, IPC_FILENAME);
      DECLARE
         RESULT      : STRING := GET_LINE (IPC_FILE);
         SPACE_INDEX : NATURAL;
      BEGIN
         SPACE_INDEX := INDEX (RESULT, " ");

         IF SPACE_INDEX = 0 THEN
            -- ERROR: SPACE CHARACTER LITERAL NOT FOUND --
            PUT_LINE ("IRIS: Unknown compare string found """ &
                      RESULT & """");
            OUTPUT := 0.0;
         ELSE
            OUTPUT := FLOAT'VALUE (RESULT (RESULT'FIRST .. SPACE_INDEX - 1));
         END IF;

      END;
      CLOSE (IPC_FILE);
      RETURN OUTPUT;
   END COMPARE;

   -------------------------
   -- CAPTURE_AND_COMPARE --
   -------------------------

   PROCEDURE CAPTURE_AND_COMPARE 
      (DIFFERENCE : OUT FLOAT)
   IS
   BEGIN
      DECLARE
      BEGIN
         CASE NEXT_IMAGE IS
            WHEN A =>
               CAPTURE (IMAGE_A_FILENAME);
               A_CAPTURE_TIME := CLOCK;
               NEXT_IMAGE     := B;
            WHEN B =>
               CAPTURE (IMAGE_B_FILENAME);
               B_CAPTURE_TIME := CLOCK;
               NEXT_IMAGE     := A;
         END CASE;
      END;
      DIFFERENCE := COMPARE;
   END CAPTURE_AND_COMPARE;
BEGIN

   IF ARGUMENT_COUNT = 1 THEN
      CAMERA_NAME := TO_UNBOUNDED_STRING (ARGUMENT (1));
   END IF;

   LIVE_VIEWER.START (IMAGE_A_FILENAME, LIVE_VIEWER_ID);
   DIFF_VIEWER.START (DIFF,             DIFF_VIEWER_ID);

   LOOP
      CAPTURE_AND_COMPARE (DIFF_AMOUNT);

      IF PREV_DIFF_AMOUNT /= 0.0 THEN
         DECLARE
            PERCENT_CHANGE : FLOAT :=
               ABS (DIFF_AMOUNT - PREV_DIFF_AMOUNT) / PREV_DIFF_AMOUNT;
         BEGIN
            IF MOTION_DEBUG THEN
               PUT ("Motion Sensor:");
               FLOAT_TEXT_IO.PUT (DIFF_AMOUNT, 6, 0, 0);
               PUT (" ");
               FLOAT_TEXT_IO.PUT (PERCENT_CHANGE, 2, 2, 0);
               NEW_LINE;
            END IF;
            IF PERCENT_CHANGE > TRIGGER_THRESHOLD THEN
               CAPTURES_REMAINING := CAPTURE_COUNT; 
               PUT_LINE ("   [CAPTURE TRIGGERED]");
            END IF;
         END;
      END IF;
         
      PREV_DIFF_AMOUNT := DIFF_AMOUNT;

      DECLARE
         USE GNAT.CALENDAR.TIME_IO;
      BEGIN
         IF CAPTURES_REMAINING = CAPTURE_COUNT THEN
            COPY_FILE (IMAGE_A_FILENAME,
                       TO_STRING (LOG_DIRECTORY) &
                       "/" &
                       IMAGE (A_CAPTURE_TIME, LOG_FILENAME));
            COPY_FILE (IMAGE_B_FILENAME,
                       TO_STRING (LOG_DIRECTORY) &
                       "/" &
                       IMAGE (B_CAPTURE_TIME, LOG_FILENAME));
            CAPTURES_REMAINING := CAPTURES_REMAINING - 1;
         ELSIF CAPTURES_REMAINING > 0 THEN
            CASE NEXT_IMAGE IS
               WHEN A =>
                  COPY_FILE (IMAGE_B_FILENAME,
                             TO_STRING (LOG_DIRECTORY) &
                             "/" &
                             IMAGE (B_CAPTURE_TIME, LOG_FILENAME));
               WHEN B =>
                  COPY_FILE (IMAGE_A_FILENAME,
                             TO_STRING (LOG_DIRECTORY) &
                             "/" &
                             IMAGE (A_CAPTURE_TIME, LOG_FILENAME));
            END CASE;
            CAPTURES_REMAINING := CAPTURES_REMAINING - 1;
         END IF;
      END;

      IF SIGINT THEN
         ABORT_TASK (LIVE_VIEWER_ID);
         ABORT_TASK (DIFF_VIEWER_ID);
         EXIT;
      END IF;
   END LOOP;
EXCEPTION
   WHEN ERROR: OTHERS =>
      PUT ("IRIS: ");
      PUT (EXCEPTION_INFORMATION (ERROR));
END IRIS;