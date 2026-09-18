/* motor_control.c
 *
 * TB6612FNG + STM32F103C8T6 (Blue Pill) — HAL
 *
 * TB6612FNG pinout assumed:
 *
 *   STBY  -> any GPIO, pulled HIGH to enable driver
 *
 *   AIN1  -> GPIO (Motor A direction bit 1)
 *   AIN2  -> GPIO (Motor A direction bit 2)
 *   PWMA  -> TIM_CH (PWM, Motor A speed)
 *
 *   BIN1  -> GPIO (Motor B direction bit 1)
 *   BIN2  -> GPIO (Motor B direction bit 2)
 *   PWMB  -> TIM_CH (PWM, Motor B speed)
 *
 *   Motor A = LEFT wheel
 *   Motor B = RIGHT wheel
 *
 * In CubeMX:
 *   - Enable one timer (e.g. TIM2) with two PWM channels
 *   - Set prescaler and ARR for ~1kHz PWM
 *     e.g. 72MHz / 72 = 1MHz timer clock, ARR = 999 -> 1kHz
 *   - AIN1, AIN2, BIN1, BIN2, STBY as GPIO Output
 */

#include "main.h"

/* --------------------------------------------------------
 * CONFIGURATION — match these to your CubeMX pin names
 * -------------------------------------------------------- */

/* STBY pin — pull HIGH to enable the driver */
#define STBY_PORT       GPIOB
#define STBY_PIN        GPIO_PIN_0

/* Motor A (LEFT) direction pins */
#define AIN1_PORT       GPIOA
#define AIN1_PIN        GPIO_PIN_1

#define AIN2_PORT       GPIOA
#define AIN2_PIN        GPIO_PIN_2

/* Motor B (RIGHT) direction pins */
#define BIN1_PORT       GPIOA
#define BIN1_PIN        GPIO_PIN_3

#define BIN2_PORT       GPIOA
#define BIN2_PIN        GPIO_PIN_4

/* PWM timer handle and channels — match what CubeMX generated */
#define PWM_TIMER       &htim2
#define PWM_CH_LEFT     TIM_CHANNEL_1
#define PWM_CH_RIGHT    TIM_CHANNEL_2

/* ARR value you set in CubeMX (period register)
 * If ARR = 999, full speed = 999, half = 499, etc. */
#define PWM_MAX         999

/* Speed settings */
#define SPEED_FULL      (PWM_MAX)
#define SPEED_TURN_INNER  (PWM_MAX / 4)   /* 25% for inner wheel on turns */

/* Declare the timer handle (CubeMX puts this in main.c) */
extern TIM_HandleTypeDef htim2;


/* --------------------------------------------------------
 * SET MOTOR SPEED
 * channel : TIM_CHANNEL_1 or TIM_CHANNEL_2
 * speed   : 0 to PWM_MAX
 * -------------------------------------------------------- */
static void set_speed(uint32_t channel, uint16_t speed)
{
    __HAL_TIM_SET_COMPARE(PWM_TIMER, channel, speed);
}


/* --------------------------------------------------------
 * SET MOTOR DIRECTION
 *
 * TB6612FNG truth table:
 *   IN1=1, IN2=0  -> forward
 *   IN1=0, IN2=1  -> backward
 *   IN1=0, IN2=0  -> coast (free spin)
 *   IN1=1, IN2=1  -> brake (active stop)
 * -------------------------------------------------------- */
static void set_direction_left(GPIO_PinState in1, GPIO_PinState in2)
{
    HAL_GPIO_WritePin(AIN1_PORT, AIN1_PIN, in1);
    HAL_GPIO_WritePin(AIN2_PORT, AIN2_PIN, in2);
}

static void set_direction_right(GPIO_PinState in1, GPIO_PinState in2)
{
    HAL_GPIO_WritePin(BIN1_PORT, BIN1_PIN, in1);
    HAL_GPIO_WritePin(BIN2_PORT, BIN2_PIN, in2);
}


/* --------------------------------------------------------
 * MOTOR INIT
 * Call this once after HAL_Init and MX_TIMx_Init
 * -------------------------------------------------------- */
void motors_init(void)
{
    /* Enable driver */
    HAL_GPIO_WritePin(STBY_PORT, STBY_PIN, GPIO_PIN_SET);

    /* Start PWM on both channels */
    HAL_TIM_PWM_Start(PWM_TIMER, PWM_CH_LEFT);
    HAL_TIM_PWM_Start(PWM_TIMER, PWM_CH_RIGHT);

    /* Start in stopped state */
    set_speed(PWM_CH_LEFT,  0);
    set_speed(PWM_CH_RIGHT, 0);

    set_direction_left (GPIO_PIN_LOW, GPIO_PIN_LOW);
    set_direction_right(GPIO_PIN_LOW, GPIO_PIN_LOW);
}


/* --------------------------------------------------------
 * COMMANDS
 * -------------------------------------------------------- */

void cmd_forward(void)
{
    set_direction_left (GPIO_PIN_SET, GPIO_PIN_RESET);
    set_direction_right(GPIO_PIN_SET, GPIO_PIN_RESET);
    set_speed(PWM_CH_LEFT,  SPEED_FULL);
    set_speed(PWM_CH_RIGHT, SPEED_FULL);
}

void cmd_backward(void)
{
    set_direction_left (GPIO_PIN_RESET, GPIO_PIN_SET);
    set_direction_right(GPIO_PIN_RESET, GPIO_PIN_SET);
    set_speed(PWM_CH_LEFT,  SPEED_FULL);
    set_speed(PWM_CH_RIGHT, SPEED_FULL);
}

void cmd_left(void)
{
    /* Right wheel full, left wheel at 25% — arcs left */
    set_direction_left (GPIO_PIN_SET, GPIO_PIN_RESET);
    set_direction_right(GPIO_PIN_SET, GPIO_PIN_RESET);
    set_speed(PWM_CH_LEFT,  SPEED_TURN_INNER);
    set_speed(PWM_CH_RIGHT, SPEED_FULL);
}

void cmd_right(void)
{
    /* Left wheel full, right wheel at 25% — arcs right */
    set_direction_left (GPIO_PIN_SET, GPIO_PIN_RESET);
    set_direction_right(GPIO_PIN_SET, GPIO_PIN_RESET);
    set_speed(PWM_CH_LEFT,  SPEED_FULL);
    set_speed(PWM_CH_RIGHT, SPEED_TURN_INNER);
}

void cmd_stop(void)
{
    /* Active brake: IN1=1, IN2=1 on both sides */
    set_direction_left (GPIO_PIN_SET, GPIO_PIN_SET);
    set_direction_right(GPIO_PIN_SET, GPIO_PIN_SET);
    set_speed(PWM_CH_LEFT,  SPEED_FULL);
    set_speed(PWM_CH_RIGHT, SPEED_FULL);
}


/* --------------------------------------------------------
 * BLUETOOTH COMMAND HANDLER
 *
 * Call this from your UART receive callback.
 * Expects single-byte commands: F, B, L, R, S
 * -------------------------------------------------------- */
void handle_command(uint8_t cmd)
{
    switch (cmd)
    {
        case 'F': cmd_forward();  break;
        case 'B': cmd_backward(); break;
        case 'L': cmd_left();     break;
        case 'R': cmd_right();    break;
        case 'S': cmd_stop();     break;
        default:  cmd_stop();     break;  /* unknown byte -> safe stop */
    }
}