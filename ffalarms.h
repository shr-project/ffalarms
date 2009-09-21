#ifndef FFALARMS_H
#define FFALARMS_H

/* from patch by Michael 'Mickey' Lauer for EFL header files
 * (http://www.mail-archive.com/enlightenment-devel@lists.sourceforge.net/msg22207.html)
 * until EFL snapshot 062 (SVN revision 41533) hits SHR unstable
 */
typedef void (*Edje_Signal_Cb) (void *data, Evas_Object *obj, const char *emission, const char *source);
typedef void (*Edje_Text_Change_Cb) (void *data, Evas_Object *obj, const char *part);
typedef void (*Edje_Message_Handler_Cb) (void *data, Evas_Object *obj, Edje_Message_Type type, int id, void *msg);
typedef void (*Evas_Smart_Cb) (void *data, Evas_Object *obj, void *event_info);

#endif
